"""Occupations, sources et conflits horaires.

La saisie manuelle est le mode dégradé du système : elle doit rester utilisable
en trente secondes, même quand toutes les collectes sont en panne.
"""

from datetime import datetime, timedelta

from fastapi import APIRouter, HTTPException, status
from psycopg.types.json import Json
from pydantic import BaseModel, Field

from api.base import connexion, executer, lister, un_seul
from api.collecteurs.service import CollecteImpossible, collecter_source
from api.config import configuration
from api.securite import Authentifie

routeur = APIRouter(tags=["Contraintes"])

CORRESPONDANCE_ERREURS = {
    "introuvable": status.HTTP_404_NOT_FOUND,
    "collecte_impossible": status.HTTP_400_BAD_REQUEST,
    "url_absente": status.HTTP_409_CONFLICT,
    "sans_proprietaire": status.HTTP_409_CONFLICT,
}


class DemandeOccupation(BaseModel):
    id_utilisateur: int | None = None
    type: str
    libelle: str
    debut: datetime
    fin: datetime
    lieu: str | None = None


@routeur.get("/occupations", summary="Occupations sur une période")
def lister_occupations(
    qui: Authentifie,
    debut: datetime | None = None,
    fin: datetime | None = None,
    utilisateur: int | None = None,
) -> list[dict]:
    debut = debut or datetime.now().astimezone()
    fin = fin or debut + timedelta(days=configuration().horizon_jours)

    return lister(
        """
        SELECT o.id_occupation, o.id_utilisateur, u.pseudo, o.type, o.libelle,
               lower(o.periode) AS debut, upper(o.periode) AS fin,
               o.lieu, o.details, o.cle_externe, s.code AS source, o.date_collecte
          FROM occupation o
          JOIN utilisateur u ON u.id_utilisateur = o.id_utilisateur
          JOIN source s      ON s.id_source = o.id_source
         WHERE o.periode && tstzrange(%(debut)s, %(fin)s, '[)')
           AND (%(utilisateur)s::INT IS NULL OR o.id_utilisateur = %(utilisateur)s::INT)
         ORDER BY lower(o.periode)
        """,
        {"debut": debut, "fin": fin, "utilisateur": utilisateur},
    )


@routeur.post("/occupations", status_code=status.HTTP_201_CREATED,
              summary="Saisir une occupation à la main")
def creer_occupation(demande: DemandeOccupation, qui: Authentifie) -> dict:
    cree = executer(
        """
        INSERT INTO occupation (id_utilisateur, id_source, type, libelle, periode, lieu)
        VALUES (COALESCE(%(utilisateur)s, %(appelant)s),
                (SELECT id_source FROM source WHERE code = 'MANUELLE'),
                %(type)s, %(libelle)s,
                tstzrange(%(debut)s, %(fin)s, '[)'),
                %(lieu)s)
        RETURNING id_occupation, lower(periode) AS debut, upper(periode) AS fin, libelle, type
        """,
        {
            "utilisateur": demande.id_utilisateur,
            "appelant": qui.id_utilisateur,
            "type": demande.type,
            "libelle": demande.libelle,
            "debut": demande.debut,
            "fin": demande.fin,
            "lieu": demande.lieu,
        },
    )
    assert cree is not None
    return cree


@routeur.delete("/occupations/{id_occupation}", status_code=status.HTTP_204_NO_CONTENT,
                summary="Supprimer une occupation")
def supprimer_occupation(id_occupation: int, qui: Authentifie) -> None:
    supprime = executer(
        "DELETE FROM occupation WHERE id_occupation = %(id)s RETURNING id_occupation",
        {"id": id_occupation},
    )
    if supprime is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"code": "introuvable", "message": f"Occupation {id_occupation} inconnue"},
        )


# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------

@routeur.get("/sources", summary="Sources et leur état de fraîcheur")
def sources(qui: Authentifie) -> list[dict]:
    # L'état est calculé par la vue : une source périmée doit être visible,
    # pas silencieuse.
    return lister("SELECT * FROM v_source_sante ORDER BY code")


@routeur.post("/sources/{code}/collecter", summary="Forcer une collecte")
def collecter(code: str, qui: Authentifie, texte_ics: str | None = None) -> dict:
    """Récupère la source, normalise et réconcilie par clé externe.

    `texte_ics` sert à rejouer un flux déjà téléchargé, sans réseau.
    """
    try:
        return collecter_source(code, qui.id_utilisateur, texte_ics)
    except CollecteImpossible as erreur:
        raise HTTPException(
            status_code=CORRESPONDANCE_ERREURS.get(erreur.code, status.HTTP_400_BAD_REQUEST),
            detail={"code": erreur.code, "message": erreur.message},
        ) from erreur


class ReglageSource(BaseModel):
    url: str | None = None
    configuration: dict | None = Field(
        default=None,
        description="Fusionné dans la configuration existante, clé par clé",
    )
    active: bool | None = None


@routeur.patch("/sources/{code}", summary="Configurer une source")
def regler_source(code: str, demande: ReglageSource, qui: Authentifie) -> dict:
    """Donne ou remplace l'URL d'un flux, depuis le bot ou l'application.

    C'est ici qu'atterrit le lien qu'on colle dans Telegram. L'URL n'est jamais
    écrite dans le dépôt : celle du planning de travail contient un jeton
    d'accès personnel.
    """
    champs = demande.model_dump(exclude_none=True)
    if not champs:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={"code": "rien_a_modifier", "message": "Aucun champ fourni"},
        )

    if "url" in champs:
        from api.conversation import url_collectable

        # Les applications de calendrier proposent des liens « webcal:// ».
        # Ce n'est pas un protocole, seulement du HTTPS déguisé.
        champs["url"] = url_collectable(champs["url"])
        # Donner l'URL vaut demande de collecte : une source renseignée mais
        # laissée éteinte n'a pas de raison d'être.
        champs.setdefault("active", True)

    # La configuration se complète, elle ne se remplace pas : changer de groupe
    # de TD ne doit pas effacer le profil de collecte ni les langues suivies.
    # L'opérateur || de JSONB écrase les clés fournies et laisse les autres.
    fusion = "configuration"
    if "configuration" in champs:
        champs["configuration"] = Json(champs["configuration"])
        fusion = "COALESCE(configuration, '{}'::JSONB) || %(configuration)s"

    affectations = ", ".join(
        f"{nom} = {fusion if nom == 'configuration' else f'%({nom})s'}"
        for nom in champs
    )
    modifiee = executer(
        f"UPDATE source SET {affectations} WHERE code = %(code)s "
        f"RETURNING id_source, code, mode_collecte, configuration, active, "
        f"(url IS NOT NULL) AS url_renseignee",
        {**champs, "code": code},
    )
    if modifiee is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"code": "introuvable", "message": f"Source {code} inconnue"},
        )
    # L'URL n'est jamais renvoyée : elle peut contenir un jeton.
    return modifiee


# ---------------------------------------------------------------------------
# Conflits horaires
# ---------------------------------------------------------------------------

@routeur.get("/conflits", summary="Conflits horaires en attente d'arbitrage")
def lister_conflits(qui: Authentifie, tous: bool = False) -> list[dict]:
    return lister(
        """
        SELECT * FROM v_conflit
         WHERE (%(tous)s::BOOLEAN OR (statut = 'en_attente' AND a_arbitrer))
         ORDER BY debut_nouvelle
        """,
        {"tous": tous},
    )


class Arbitrage(BaseModel):
    garder: str = Field(description="existante ou nouvelle")


@routeur.post("/conflits/{id_conflit}/resoudre", summary="Trancher un conflit horaire")
def resoudre_conflit(id_conflit: int, demande: Arbitrage, qui: Authentifie) -> dict:
    if demande.garder not in ("existante", "nouvelle"):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={"code": "choix_invalide",
                    "message": "garder doit valoir 'existante' ou 'nouvelle'"},
        )

    conflit = un_seul(
        "SELECT * FROM conflit WHERE id_conflit = %(id)s AND statut = 'en_attente'",
        {"id": id_conflit},
    )
    if conflit is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"code": "introuvable",
                    "message": f"Conflit {id_conflit} inconnu ou déjà tranché"},
        )

    with connexion() as conn, conn.cursor() as cur:
        if demande.garder == "nouvelle":
            # Suppression avant insertion : la contrainte d'exclusion
            # interdit que les deux versions coexistent.
            cur.execute("DELETE FROM occupation WHERE id_occupation = %(o)s",
                        {"o": conflit["id_occupation"]})
            cur.execute(
                """
                INSERT INTO occupation (id_utilisateur, id_source, type, libelle,
                                        periode, lieu, details, cle_externe)
                VALUES (%(u)s, %(s)s, 'cours', %(libelle)s, %(periode)s,
                        %(lieu)s, %(details)s, %(cle)s)
                """,
                {
                    "u": qui.id_utilisateur,
                    "s": conflit["id_source"],
                    "libelle": conflit["libelle"],
                    "periode": conflit["periode"],
                    "lieu": conflit["lieu"],
                    "details": conflit["details"],
                    "cle": conflit["cle_externe"],
                },
            )

        cur.execute(
            """
            UPDATE conflit
               SET statut = 'resolu', choix = %(choix)s, date_resolution = now()
             WHERE id_conflit = %(id)s
            """,
            {"id": id_conflit, "choix": demande.garder},
        )

    return {"id_conflit": id_conflit, "garde": demande.garder, "statut": "resolu"}
