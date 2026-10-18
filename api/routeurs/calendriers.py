"""Les calendriers à suivre, depuis l'appli          (COL-7, COL-14, COL-17, COL-21)

Réglages, Calendriers à suivre [5.3] et Ajouter un calendrier [5.4]. Ce que le
bot faisait par « /lien », « /groupe », « /ecarter » et « /arreter » se fait ici.

Les droits vivent dans la base : on règle les calendriers de son foyer, et on
n'en ajoute que pour un de ses membres (`calendrier_du_foyer`,
`suivre_calendrier`). L'URL n'est jamais rendue ni journalisée : celle d'un
planning de travail porte un jeton personnel (COL-7, JRN-3).

COL-7 : avant d'enregistrer un lien, l'appli l'essaie. Le serveur le lit sans
rien garder, et rend le prochain événement à montrer.

La collecte forcée reste au réseau privé (CNX-5). Donner un lien, changer de
groupe ou écarter une UE relance seulement la collecte de ce calendrier, comme
le bot le faisait.
"""

import logging
from datetime import UTC, datetime, timedelta
from typing import Literal

import httpx
from fastapi import APIRouter, HTTPException, status
from psycopg.types.json import Jsonb
from pydantic import BaseModel, Field

from api import conversation as conv
from api.base import executer, lister, un_seul
from api.collecteurs import ics
from api.collecteurs.service import CollecteImpossible, collecter_source
from api.securite import Authentifie

LOG = logging.getLogger(__name__)

routeur = APIRouter(prefix="/appli/calendriers", tags=["Appli"])

# Ce que l'appli appelle « cours », « travail » et « perso », et le profil de
# lecture que l'essai emprunte pour montrer les titres tels qu'ils seront.
PROFILS = {"cours": "ade", "travail": "perso", "perso": "perso"}

# L'essai d'un lien : assez pour voir que c'est un calendrier, pas une collecte.
ESSAI_JOURS = 60
ESSAI_PROCHAINS = 3


def _liste(moi: int) -> list[dict]:
    """Les calendriers suivis du foyer : les miens d'abord, les actifs ensuite."""
    return lister(
        """
        SELECT s.id_source AS id, s.code, s.libelle, s.active,
               s.url IS NOT NULL AS lien_donne,
               CASE s.configuration ->> 'type_occupation'
                    WHEN 'cours' THEN 'cours' WHEN 'travail' THEN 'travail'
                    ELSE 'perso' END AS nature,
               s.configuration ->> 'profil' = 'ade' AS ade,
               NULLIF(s.configuration ->> 'groupe', '')::INTEGER AS groupe,
               COALESCE(s.configuration -> 'cours_ecartes', '[]'::JSONB) AS cours_ecartes,
               s.derniere_collecte, v.etat_calcule AS etat,
               s.id_utilisateur AS pour, u.nom AS pour_nom,
               (SELECT count(*) FROM occupation o
                 WHERE o.id_source = s.id_source AND upper(o.periode) > now())::INTEGER
                   AS a_venir,
               (SELECT json_build_object('titre', o.libelle, 'debut', lower(o.periode),
                                         'fin', upper(o.periode), 'lieu', o.lieu)
                  FROM occupation o
                 WHERE o.id_source = s.id_source AND upper(o.periode) > now()
                 ORDER BY lower(o.periode) LIMIT 1) AS prochain
          FROM source s
          JOIN v_source_sante v ON v.id_source = s.id_source
          JOIN utilisateur u ON u.id_utilisateur = s.id_utilisateur
         WHERE s.mode_collecte = 'ics'
           AND (s.id_utilisateur = %(moi)s
                OR foyer_de(s.id_utilisateur) = foyer_de(%(moi)s))
         ORDER BY s.id_utilisateur <> %(moi)s, s.active DESC, s.url IS NULL, s.libelle
        """,
        {"moi": moi},
    )


def _un(moi: int, id_source: int) -> dict:
    trouve = next((c for c in _liste(moi) if c["id"] == id_source), None)
    if trouve is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"code": "introuvable", "message": "Ce calendrier n'existe pas"})
    return trouve


def _recollecter(code: str) -> dict:
    """La collecte de ce calendrier, puis le placement : ce qu'il bloquait se libère.

    Un échec ne défait rien de ce qui précède : le lien est gardé, et la
    source finit en panne si le flux ne répond toujours pas (COL-9).
    """
    from api.ordonnanceur import placer

    try:
        bilan = collecter_source(code)
    except CollecteImpossible as refus:
        return {"erreur": refus.message}
    except httpx.HTTPError:
        return {"erreur": "Le lien ne répond pas pour l'instant : la collecte réessaiera seule"}
    except Exception:
        # Le lien est déjà enregistré : une lecture qui casse ne doit pas faire
        # croire à l'appli que rien n'a été pris en compte (une erreur 500).
        LOG.exception("Lecture de %s impossible après un réglage", code)
        return {"erreur": "Le lien est gardé, mais ce calendrier n'a pas pu être lu. "
                          "La collecte réessaiera seule."}
    placer()
    return {"lues": bilan["lues"], "crees": bilan["crees"], "mis_a_jour": bilan["mis_a_jour"],
            "annules": bilan["annules"], "conflits": len(bilan["conflits"])}


@routeur.get("", summary="Les calendriers suivis du foyer, et leur état")
def lister_calendriers(qui: Authentifie) -> list[dict]:
    return _liste(qui.id_utilisateur)


# -----------------------------------------------------------------------------
# Essayer un lien, puis l'ajouter                                (COL-7, COL-14)
# -----------------------------------------------------------------------------
class Lien(BaseModel):
    url: str = Field(min_length=8, max_length=2000)
    nature: Literal["cours", "travail", "perso"] = "perso"


def _refus_du_lien(message: str) -> HTTPException:
    return HTTPException(status_code=422, detail={"code": "lien_illisible", "message": message})


@routeur.post("/essai", summary="Lire un lien sans rien garder : le prochain événement")
def essayer(lien: Lien, qui: Authentifie) -> dict:
    """COL-7 : l'appli montre ce que le lien donne avant de l'enregistrer.

    Rien n'est écrit, ni en base ni au journal : l'URL peut porter un jeton.
    """
    url = conv.url_collectable(lien.url)
    if not url.lower().startswith(("https://", "http://")):
        raise _refus_du_lien("Le lien doit commencer par https:// ou webcal://")
    try:
        texte = ics.recuperer(url, horizon_jours=ESSAI_JOURS, delai=15.0)
    except httpx.HTTPStatusError as erreur:
        code = erreur.response.status_code
        raise _refus_du_lien(f"Ce lien répond {code} : vérifie qu'il est bien publié") from None
    except httpx.HTTPError:
        raise _refus_du_lien("Ce lien ne répond pas : vérifie l'adresse") from None

    maintenant = datetime.now(UTC)
    try:
        seances = ics.analyser(texte, PROFILS[lien.nature], maintenant - timedelta(days=1),
                               maintenant + timedelta(days=ESSAI_JOURS))
    except Exception:
        LOG.info("Essai d'un lien : réponse qui n'est pas un calendrier")
        raise _refus_du_lien("Ce lien ne donne pas un calendrier") from None

    a_venir = [s for s in seances if s.fin > maintenant]
    return {
        "a_venir": len(a_venir),
        "prochains": [
            {"titre": s.libelle, "debut": s.debut, "fin": s.fin, "lieu": s.lieu,
             "journee_entiere": s.journee_entiere}
            for s in a_venir[:ESSAI_PROCHAINS]
        ],
    }


class NouveauCalendrier(Lien):
    pour: int | None = Field(default=None, description="Un membre du foyer ; soi par défaut")
    libelle: str | None = Field(default=None, max_length=100)


@routeur.post("", status_code=status.HTTP_201_CREATED, summary="Suivre un nouveau calendrier")
def ajouter(nouveau: NouveauCalendrier, qui: Authentifie) -> dict:
    cree = executer(
        "SELECT suivre_calendrier(%(moi)s, %(pour)s, %(nature)s, %(libelle)s, %(url)s) AS id",
        {"moi": qui.id_utilisateur, "pour": nouveau.pour or qui.id_utilisateur,
         "nature": nouveau.nature, "libelle": nouveau.libelle,
         "url": conv.url_collectable(nouveau.url)},
    )
    assert cree is not None
    calendrier = _un(qui.id_utilisateur, cree["id"])
    collecte = _recollecter(calendrier["code"])
    return {"calendrier": _un(qui.id_utilisateur, cree["id"]), "collecte": collecte}


class NouveauLien(BaseModel):
    url: str = Field(min_length=8, max_length=2000)


@routeur.put("/{id_source}/lien", summary="Donner ou changer le lien d'un calendrier")
def changer_lien(id_source: int, lien: NouveauLien, qui: Authentifie) -> dict:
    ligne = executer(
        "SELECT changer_lien_calendrier(%(moi)s, %(id)s, %(url)s) AS code",
        {"moi": qui.id_utilisateur, "id": id_source, "url": conv.url_collectable(lien.url)},
    )
    assert ligne is not None
    collecte = _recollecter(ligne["code"])
    return {"calendrier": _un(qui.id_utilisateur, id_source), "collecte": collecte}


# -----------------------------------------------------------------------------
# Régler un calendrier : nom, groupe de TD, UE écartées               (COL-17)
# -----------------------------------------------------------------------------
class Reglage(BaseModel):
    libelle: str | None = Field(default=None, min_length=1, max_length=100)
    groupe: int | None = Field(default=None, ge=0, le=99,
                               description="0 : tous les groupes")
    cours_ecartes: list[str] | None = Field(default=None, max_length=50)


def _code(moi: int, id_source: int) -> str:
    ligne = un_seul("SELECT calendrier_du_foyer(%(moi)s, %(id)s) AS code",
                    {"moi": moi, "id": id_source})
    assert ligne is not None
    return ligne["code"]


@routeur.patch("/{id_source}", summary="Renommer, changer de groupe, écarter des UE")
def regler(id_source: int, reglage: Reglage, qui: Authentifie) -> dict:
    code = _code(qui.id_utilisateur, id_source)
    filtre = {}
    if reglage.groupe is not None:
        filtre["groupe"] = reglage.groupe or None
    if reglage.cours_ecartes is not None:
        # Un libellé par cours, sans doublon ni ligne vide, dans l'ordre donné.
        vus: dict[str, str] = {}
        for cours in reglage.cours_ecartes:
            propre = cours.strip()[:100]
            if propre:
                vus.setdefault(propre.lower(), propre)
        filtre["cours_ecartes"] = list(vus.values())

    executer(
        """UPDATE source
              SET libelle = COALESCE(%(libelle)s, libelle),
                  configuration = COALESCE(configuration, '{}'::JSONB) || %(filtre)s::JSONB
            WHERE id_source = %(id)s""",
        {"libelle": reglage.libelle, "filtre": Jsonb(filtre), "id": id_source},
    )
    # Le filtre change ce que le flux retient : la collecte retire ce qui n'en
    # fait plus partie, et pose le reste (COL-17, COL-20).
    collecte = _recollecter(code) if filtre else None
    return {"calendrier": _un(qui.id_utilisateur, id_source), "collecte": collecte}


@routeur.post("/{id_source}/arreter", summary="Ne plus suivre un calendrier")
def arreter(id_source: int, qui: Authentifie) -> dict:
    """COL-21 : il n'est plus collecté, son avenir quitte le planning, son passé
    reste. Le lien est gardé : le reprendre ne demande que de le redonner."""
    bilan = conv.arreter_source(_code(qui.id_utilisateur, id_source))
    assert bilan is not None
    return {"calendrier": _un(qui.id_utilisateur, id_source),
            "retirees": bilan["occupations_retirees"]}


@routeur.post("/{id_source}/reprendre", summary="Suivre de nouveau un calendrier arrêté")
def reprendre(id_source: int, qui: Authentifie) -> dict:
    code = _code(qui.id_utilisateur, id_source)
    if not _un(qui.id_utilisateur, id_source)["lien_donne"]:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={"code": "lien_absent",
                    "message": "Ce calendrier n'a pas de lien : donne-le d'abord"})
    executer("UPDATE source SET active = TRUE, etat = 'ok' WHERE id_source = %(id)s",
             {"id": id_source})
    collecte = _recollecter(code)
    return {"calendrier": _un(qui.id_utilisateur, id_source), "collecte": collecte}
