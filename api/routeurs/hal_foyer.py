"""Le HAL du foyer : sa mémoire et ses conversations            (HDF-4, HDF-5)

La mémoire est au foyer : chaque membre la lit et la corrige, et sa correction
est signée de lui. Les conversations, elles, restent à celui qui les a eues :
cette route ne rend que les siennes.
"""

from datetime import date
from typing import Literal

from fastapi import APIRouter, HTTPException, Query, status
from pydantic import BaseModel, Field

from api.base import lister
from api.coach import foyer, reponse
from api.securite import Authentifie

routeur = APIRouter(prefix="/hal-foyer", tags=["HAL du foyer"])


class Correction(BaseModel):
    niveau: Literal["globale", "semaine"]
    texte: str = Field(max_length=4000)
    # Une semaine passée se corrige aussi ; sans date, la semaine en cours.
    periode: date | None = None


def _foyer_de(id_utilisateur: int) -> int:
    id_foyer = foyer.foyer_de(id_utilisateur)
    if id_foyer is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"code": "aucun_foyer", "message": "Ce compte ne fait partie d'aucun foyer"})
    return id_foyer


@routeur.get("/memoire", summary="La mémoire du foyer, étage par étage")
def lire_memoire(qui: Authentifie) -> dict:
    e = foyer.etat_memoire(_foyer_de(qui.id_utilisateur))
    return {"globale": e["globale"], "semaine": e["semaine"],
            "semaines_passees": e["semaines_passees"], "lundi": e["lundi"]}


@routeur.put("/memoire", summary="Corriger un étage de la mémoire du foyer")
def corriger_memoire(qui: Authentifie, correction: Correction) -> dict:
    """HDF-4 : la correction d'un membre est une version de plus, signée de lui."""
    foyer.ecrire(_foyer_de(qui.id_utilisateur), correction.niveau, correction.texte,
                 "utilisateur", qui.id_utilisateur, correction.periode)
    return lire_memoire(qui)


@routeur.get("/echanges", summary="Mes conversations avec le HAL du foyer")
def relire_echanges(qui: Authentifie,
                    limite: int = Query(default=20, ge=1, le=200)) -> list[dict]:
    """HDF-5 : celles de l'appelant seul."""
    lignes = lister(
        """SELECT id_echange, quand, auteur, moment, contenu, elements, client, hal
             FROM echange
            WHERE id_utilisateur = %(u)s AND hal IN ('foyer', 'les_deux')
            ORDER BY id_echange DESC LIMIT %(n)s""",
        {"u": qui.id_utilisateur, "n": limite})
    rendus = []
    for ligne in lignes:
        rendu = reponse.depuis_echange(ligne)
        rendu["elements"] = reponse.etat_des_elements(qui.id_utilisateur,
                                                      list(rendu["elements"] or []))
        rendus.append(rendu)
    return rendus
