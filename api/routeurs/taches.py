"""Définitions de tâches récurrentes."""

from datetime import time

from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel, Field

from api.base import executer, lister, un_seul
from api.securite import Administrateur, Authentifie

routeur = APIRouter(prefix="/taches", tags=["Tâches"])


class DemandeTache(BaseModel):
    code: str = Field(pattern=r"^[A-Z0-9_]{3,30}$")
    libelle: str
    categorie: str
    priorite: int = Field(default=3, ge=1, le=5)
    duree_minutes: int = Field(gt=0)
    periodicite_min_jours: int = Field(gt=0)
    periodicite_max_jours: int = Field(gt=0)
    rappel_journee: bool = True
    heure_min: time | None = None
    heure_max: time | None = None
    utilise_machine: bool = False
    requiert_les_deux: bool = False
    reportable: bool = True
    id_utilisateur_defaut: int | None = None


class ModificationTache(BaseModel):
    libelle: str | None = None
    priorite: int | None = Field(default=None, ge=1, le=5)
    duree_minutes: int | None = Field(default=None, gt=0)
    periodicite_min_jours: int | None = Field(default=None, gt=0)
    periodicite_max_jours: int | None = Field(default=None, gt=0)
    id_utilisateur_defaut: int | None = None
    active: bool | None = None


@routeur.get("", summary="Lister les tâches récurrentes")
def lister_taches(qui: Authentifie, seulement_actives: bool = True) -> list[dict]:
    return lister(
        """
        SELECT t.*,
               (SELECT json_agg(json_build_object(
                           'id_tache_suivante', e.id_tache_suivante,
                           'code', c.code,
                           'delai_min_heures', e.delai_min_heures,
                           'delai_max_heures', e.delai_max_heures))
                  FROM enchainement e
                  JOIN tache c ON c.id_tache = e.id_tache_suivante
                 WHERE e.id_tache_source = t.id_tache) AS declenche
          FROM tache t
         WHERE (NOT %(actives)s::BOOLEAN OR t.active)
         ORDER BY t.priorite, t.code
        """,
        {"actives": seulement_actives},
    )


@routeur.post("", status_code=status.HTTP_201_CREATED, summary="Créer une tâche")
def creer(demande: DemandeTache, qui: Administrateur) -> dict:
    cree = executer(
        """
        INSERT INTO tache (code, libelle, categorie, priorite, duree_minutes,
                           periodicite_min_jours, periodicite_max_jours,
                           rappel_journee, heure_min, heure_max, utilise_machine,
                           requiert_les_deux, reportable, id_utilisateur_defaut)
        VALUES (%(code)s, %(libelle)s, %(categorie)s, %(priorite)s, %(duree)s,
                %(min)s, %(max)s, %(rappel)s, %(hmin)s, %(hmax)s, %(machine)s,
                %(duo)s, %(reportable)s, %(defaut)s)
        RETURNING *
        """,
        {
            "code": demande.code,
            "libelle": demande.libelle,
            "categorie": demande.categorie,
            "priorite": demande.priorite,
            "duree": demande.duree_minutes,
            "min": demande.periodicite_min_jours,
            "max": demande.periodicite_max_jours,
            "rappel": demande.rappel_journee,
            "hmin": demande.heure_min,
            "hmax": demande.heure_max,
            "machine": demande.utilise_machine,
            "duo": demande.requiert_les_deux,
            "reportable": demande.reportable,
            "defaut": demande.id_utilisateur_defaut,
        },
    )
    assert cree is not None
    return cree


@routeur.patch("/{id_tache}", summary="Modifier une tâche")
def modifier(id_tache: int, demande: ModificationTache, qui: Administrateur) -> dict:
    champs = demande.model_dump(exclude_none=True)
    if not champs:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={"code": "rien_a_modifier", "message": "Aucun champ fourni"},
        )

    affectations = ", ".join(f"{nom} = %({nom})s" for nom in champs)
    modifiee = executer(
        f"UPDATE tache SET {affectations} WHERE id_tache = %(id_tache)s RETURNING *",
        {**champs, "id_tache": id_tache},
    )
    if modifiee is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"code": "introuvable", "message": f"Tâche {id_tache} inconnue"},
        )
    return modifiee


@routeur.delete("/{id_tache}", summary="Désactiver une tâche")
def desactiver(id_tache: int, qui: Administrateur) -> dict:
    # On ne supprime pas : l'historique des occurrences garde son sens.
    executer(
        """
        WITH stop AS (
            UPDATE tache SET active = FALSE WHERE id_tache = %(id)s RETURNING id_tache
        )
        UPDATE occurrence
           SET statut = 'abandonnee', motif = 'Tâche désactivée'
         WHERE id_tache IN (SELECT id_tache FROM stop)
           AND statut IN ('a_placer', 'planifiee', 'notifiee')
        """,
        {"id": id_tache},
    )
    detail = un_seul("SELECT * FROM tache WHERE id_tache = %(id)s", {"id": id_tache})
    if detail is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"code": "introuvable", "message": f"Tâche {id_tache} inconnue"},
        )
    return detail
