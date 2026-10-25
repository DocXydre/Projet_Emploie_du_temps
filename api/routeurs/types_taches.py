"""Les types de tâches du foyer                               (TAC-25, TAC-26)

Un nom, une couleur, une icône, et ce qu'une tâche nouvelle de ce type prend par
défaut. Les créer, les modifier et les supprimer suivent le droit de modifier
les tâches (FOY-6) ; la base refuse un nom déjà pris, un type encore porté, et
la suppression d'un des cinq types de base (TAC-25, TAC-26).
"""

from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel, Field

from api.base import executer, lister, un_seul
from api.routeurs.taches import _exiger_droit
from api.securite import Authentifie

routeur = APIRouter(prefix="/types-taches", tags=["Types de tâches"])

LIRE_TYPES = """
    SELECT y.id_type_tache AS id, y.libelle, y.couleur, y.icone, y.duree_minutes,
           y.priorite, COALESCE(y.base, 'menage') AS categorie, y.base,
           y.base IS NOT NULL AS de_base, y.ordre,
           (SELECT count(*) FROM tache t
             WHERE t.id_type_tache = y.id_type_tache AND t.active)::INTEGER AS taches
      FROM type_tache y
"""

COULEUR = r"^#[0-9A-Fa-f]{6}$"


class NouveauType(BaseModel):
    libelle: str = Field(min_length=1, max_length=40)
    couleur: str = Field(pattern=COULEUR)
    icone: str = Field(default="checklist", max_length=60)
    duree_minutes: int = Field(default=15, ge=1, le=480)
    priorite: int = Field(default=4, ge=1, le=5)


class ModificationType(BaseModel):
    libelle: str | None = Field(default=None, min_length=1, max_length=40)
    couleur: str | None = Field(default=None, pattern=COULEUR)
    icone: str | None = Field(default=None, max_length=60)
    duree_minutes: int | None = Field(default=None, ge=1, le=480)
    priorite: int | None = Field(default=None, ge=1, le=5)


def lire_types() -> list[dict]:
    return lister(LIRE_TYPES + " ORDER BY y.ordre, y.libelle")


def _un_type(id_type: int) -> dict:
    lu = un_seul(LIRE_TYPES + " WHERE y.id_type_tache = %(id)s", {"id": id_type})
    if lu is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"code": "introuvable", "message": "Ce type de tâche n'existe pas"},
        )
    return lu


@routeur.get("", summary="Les types du foyer et leur nombre de tâches")
def lister_types(qui: Authentifie) -> list[dict]:
    return lire_types()


@routeur.post("", status_code=status.HTTP_201_CREATED, summary="Créer un type")
def creer_type(demande: NouveauType, qui: Authentifie) -> dict:
    _exiger_droit(qui, "modifier")
    cree = executer(
        "SELECT enregistrer_type_tache(NULL, %(l)s, %(c)s, %(i)s, %(d)s, %(p)s) AS id",
        {"l": demande.libelle, "c": demande.couleur, "i": demande.icone,
         "d": demande.duree_minutes, "p": demande.priorite},
    )
    assert cree is not None
    return _un_type(cree["id"])


@routeur.patch("/{id_type}", summary="Le renommer, le recolorer, changer ses valeurs par défaut")
def modifier_type(id_type: int, demande: ModificationType, qui: Authentifie) -> dict:
    _exiger_droit(qui, "modifier")
    executer(
        "SELECT enregistrer_type_tache(%(id)s, %(l)s, %(c)s, %(i)s, %(d)s, %(p)s)",
        {"id": id_type, "l": demande.libelle, "c": demande.couleur, "i": demande.icone,
         "d": demande.duree_minutes, "p": demande.priorite},
    )
    return _un_type(id_type)


@routeur.delete("/{id_type}", summary="Le supprimer, s'il ne porte plus de tâche")
def supprimer_type(id_type: int, qui: Authentifie) -> dict:
    _exiger_droit(qui, "modifier")
    executer("SELECT supprimer_type_tache(%(id)s)", {"id": id_type})
    return {"supprime": True}
