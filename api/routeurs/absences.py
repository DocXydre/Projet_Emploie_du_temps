"""Absences : les périodes où l'on n'est pas dans l'appartement.

Une absence n'est pas une occupation. Être en cours empêche de faire le ménage
à ce moment-là ; être parti dispense de le faire — on ne salit pas un logement
où l'on n'est pas.
"""

from datetime import datetime

from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel

from api.base import executer, lister
from api.securite import Authentifie

routeur = APIRouter(prefix="/absences", tags=["Absences"])


class DemandeAbsence(BaseModel):
    debut: datetime
    fin: datetime
    lieu: str | None = None
    commentaire: str | None = None
    id_utilisateur: int | None = None


@routeur.get("", summary="Absences déclarées")
def lister_absences(qui: Authentifie, passees: bool = False) -> list[dict]:
    return lister(
        """
        SELECT a.id_absence, a.id_utilisateur, u.pseudo,
               lower(a.periode) AS debut, upper(a.periode) AS fin,
               a.lieu, a.origine, a.commentaire,
               (a.periode @> now()) AS en_cours
          FROM absence a
          JOIN utilisateur u ON u.id_utilisateur = a.id_utilisateur
         WHERE (%(passees)s::BOOLEAN OR upper(a.periode) > now())
         ORDER BY lower(a.periode)
        """,
        {"passees": passees},
    )


@routeur.post("", status_code=status.HTTP_201_CREATED, summary="Déclarer une absence")
def declarer(demande: DemandeAbsence, qui: Authentifie) -> dict:
    if demande.fin <= demande.debut:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={"code": "periode_invalide", "message": "La fin doit suivre le début"},
        )

    creee = executer(
        """
        INSERT INTO absence (id_utilisateur, periode, lieu, commentaire, origine)
        VALUES (COALESCE(%(utilisateur)s, %(appelant)s),
                tstzrange(%(debut)s, %(fin)s, '[)'),
                %(lieu)s, %(commentaire)s, 'manuelle')
        RETURNING id_absence, lower(periode) AS debut, upper(periode) AS fin, lieu
        """,
        {
            "utilisateur": demande.id_utilisateur,
            "appelant": qui.id_utilisateur,
            "debut": demande.debut,
            "fin": demande.fin,
            "lieu": demande.lieu,
            "commentaire": demande.commentaire,
        },
    )
    assert creee is not None
    return creee


@routeur.delete("/{id_absence}", status_code=status.HTTP_204_NO_CONTENT,
                summary="Annuler une absence")
def annuler(id_absence: int, qui: Authentifie) -> None:
    supprimee = executer(
        "DELETE FROM absence WHERE id_absence = %(id)s RETURNING id_absence",
        {"id": id_absence},
    )
    if supprimee is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"code": "introuvable", "message": f"Absence {id_absence} inconnue"},
        )


@routeur.get("/presence", summary="Qui est là, jour par jour")
def presence(qui: Authentifie, jours: int = 14) -> list[dict]:
    """Vue calendaire de la présence, pour comprendre d'un coup d'œil qui fait quoi."""
    return lister(
        """
        SELECT j::DATE AS jour,
               presents_le(j::DATE) AS presents,
               appartement_vide(j::DATE) AS appartement_vide
          FROM generate_series(debut_jour(jour_de(now())),
                               debut_jour(jour_de(now()) + %(jours)s),
                               INTERVAL '1 day') j
         ORDER BY j
        """,
        {"jours": max(1, min(jours, 90))},
    )
