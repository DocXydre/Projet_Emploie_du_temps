"""Les règles spéciales des tâches                          (CND-1 à CND-16)

Une règle est faite de briques : des jours et des dates, l'agenda, la présence.
Le moteur ne place une occurrence qu'un jour où toutes les règles de sa tâche
tiennent. Ici, on les pose brique par brique, à la main (CND-11) ; HAL passera
par une demande, qui appelle la même fonction (lot 17).

La base vérifie tout, écrit la traduction et refuse avec son motif ce qui ne
tient pas. Les droits sont ceux de modifier une tâche (FOY-6).
"""

from datetime import date
from typing import Any, Literal

from fastapi import APIRouter, HTTPException, status
from psycopg.types.json import Jsonb
from pydantic import BaseModel, Field

from api.base import connexion, lister, un_seul
from api.routeurs.taches import _exiger_droit, _replacer, _une_tache
from api.securite import Authentifie

routeur = APIRouter(tags=["Règles des tâches"])

# Huit semaines : ce que montre l'essai d'une règle (annexe 3).
JOURS_ESSAYES = 56
PROCHAINS_JOURS = 5

PERIODE = """CASE WHEN %(du)s::DATE IS NULL THEN NULL
                  ELSE daterange(%(du)s::DATE, %(au)s::DATE + 1, '[)') END"""


class Brique(BaseModel):
    nature: str
    pour_qui: Literal["assigne", "nomme", "les_deux"] | None = None
    id_utilisateur: int | None = None
    parametres: dict[str, Any] = Field(default_factory=dict)


class Frequence(BaseModel):
    """CND-7 : tous les `min` à `max` jours, ou `fois` par `par`."""

    min: int | None = Field(default=None, ge=1)
    max: int | None = Field(default=None, ge=1)
    fois: int | None = Field(default=None, ge=1, le=31)
    par: Literal["semaine", "mois"] | None = None


class DefinitionRegle(BaseModel):
    """Les briques, et si on veut une période (du … au …) et une fréquence."""

    briques: list[Brique] = Field(default_factory=list)
    phrase: str | None = Field(default=None, max_length=500)
    du: date | None = None
    au: date | None = None
    chaque_annee: bool = False
    frequence: Frequence | None = None


class ModificationRegle(BaseModel):
    """Un état seul suspend ou reprend ; des briques redéfinissent la règle."""

    etat: Literal["active", "suspendue"] | None = None
    briques: list[Brique] | None = None
    phrase: str | None = Field(default=None, max_length=500)
    du: date | None = None
    au: date | None = None
    chaque_annee: bool = False
    frequence: Frequence | None = None


class EssaiRegle(BaseModel):
    briques: list[Brique] = Field(default_factory=list)
    du: date | None = None
    au: date | None = None
    chaque_annee: bool = False
    jours: int = Field(default=JOURS_ESSAYES, ge=1, le=366)


def _periode(du: date | None, au: date | None) -> dict:
    if (du is None) != (au is None):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={"code": "periode_incomplete",
                    "message": "Une période a un premier et un dernier jour"},
        )
    return {"du": du, "au": au}


def _briques(briques: list[Brique] | None) -> Jsonb | None:
    if briques is None:
        return None
    return Jsonb([b.model_dump() for b in briques])


def _frequence(frequence: Frequence | None) -> Jsonb | None:
    if frequence is None:
        return None
    return Jsonb(frequence.model_dump(exclude_none=True))


def regles_de(id_tache: int) -> dict:
    """Ce que montre le détail d'une tâche : ses règles et ses prochains jours."""
    regles = lister(
        "SELECT * FROM v_regle_tache WHERE id_tache = %(t)s "
        "ORDER BY etat <> 'active', creee_le DESC",
        {"t": id_tache})
    jours = lister(
        "SELECT j AS jour FROM jours_possibles(%(t)s) j LIMIT %(n)s",
        {"t": id_tache, "n": PROCHAINS_JOURS}) if any(
            r["etat"] == "active" for r in regles) else []
    return {"regles": regles, "prochains_jours": [j["jour"] for j in jours]}


def _id_tache_de(id_regle: int) -> int:
    ligne = un_seul("SELECT id_tache FROM regle_tache WHERE id_regle_tache = %(r)s",
                    {"r": id_regle})
    if ligne is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"code": "introuvable", "message": "Cette règle n'existe pas"},
        )
    return ligne["id_tache"]


@routeur.get("/taches/{id_tache}/regles", summary="Les règles d'une tâche")
def lire_regles(id_tache: int, qui: Authentifie) -> dict:
    _une_tache(id_tache)
    return regles_de(id_tache)


@routeur.post("/taches/{id_tache}/regles", status_code=status.HTTP_201_CREATED,
              summary="Poser une règle, brique par brique")
def poser(id_tache: int, regle: DefinitionRegle, qui: Authentifie) -> dict:
    """CND-11 : la saisie à la main. La base écrit la traduction (CND-2)."""
    _exiger_droit(qui, "modifier")
    _une_tache(id_tache)
    with connexion() as conn:
        conn.execute(
            f"""SELECT poser_regle(%(t)s, %(moi)s, %(b)s, %(phrase)s, {PERIODE},
                                   %(annee)s, %(f)s)""",
            {"t": id_tache, "moi": qui.id_utilisateur, "b": _briques(regle.briques),
             "phrase": regle.phrase, **_periode(regle.du, regle.au),
             "annee": regle.chaque_annee, "f": _frequence(regle.frequence)})
    _replacer()
    return regles_de(id_tache)


@routeur.post("/taches/{id_tache}/regles/essayer",
              summary="Les jours où une règle tiendrait, sans rien écrire")
def essayer(id_tache: int, essai: EssaiRegle, qui: Authentifie) -> dict:
    """Huit semaines par défaut. Une brique mal formée est refusée avec son motif."""
    _une_tache(id_tache)
    motif = un_seul(
        f"SELECT motif_regle(%(t)s, %(b)s, {PERIODE}, %(annee)s) AS motif",
        {"t": id_tache, "b": _briques(essai.briques), **_periode(essai.du, essai.au),
         "annee": essai.chaque_annee})
    if motif and motif["motif"]:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={"code": "regle_metier", "message": motif["motif"]},
        )
    jours = lister(
        f"""SELECT j AS jour FROM jours_possibles(%(t)s, %(b)s, {PERIODE}, %(annee)s,
                                                 NULL, %(n)s) j""",
        {"t": id_tache, "b": _briques(essai.briques), **_periode(essai.du, essai.au),
         "annee": essai.chaque_annee, "n": essai.jours})
    traduction = un_seul(
        f"SELECT traduire_regle(%(b)s, {PERIODE}, %(annee)s) AS texte",
        {"b": _briques(essai.briques), **_periode(essai.du, essai.au),
         "annee": essai.chaque_annee})
    return {"traduction": (traduction or {}).get("texte"),
            "jours": [j["jour"] for j in jours]}


@routeur.patch("/regles/{id_regle}", summary="Modifier, suspendre ou reprendre une règle")
def modifier(id_regle: int, demande: ModificationRegle, qui: Authentifie) -> dict:
    _exiger_droit(qui, "modifier")
    id_tache = _id_tache_de(id_regle)
    if demande.etat is None and demande.briques is None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={"code": "rien_a_modifier", "message": "Aucun champ fourni"},
        )
    with connexion() as conn:
        conn.execute(
            f"""SELECT modifier_regle(%(r)s, %(etat)s, %(b)s, %(phrase)s, {PERIODE},
                                      %(annee)s, %(f)s)""",
            {"r": id_regle, "etat": demande.etat, "b": _briques(demande.briques),
             "phrase": demande.phrase, **_periode(demande.du, demande.au),
             "annee": demande.chaque_annee, "f": _frequence(demande.frequence)})
    _replacer()
    return regles_de(id_tache)


@routeur.delete("/regles/{id_regle}", summary="Retirer une règle")
def retirer(id_regle: int, qui: Authentifie) -> dict:
    """Elle reste dans l'historique de la tâche (CND-14)."""
    _exiger_droit(qui, "modifier")
    id_tache = _id_tache_de(id_regle)
    with connexion() as conn:
        conn.execute("SELECT retirer_regle(%(r)s)", {"r": id_regle})
    _replacer()
    return regles_de(id_tache)
