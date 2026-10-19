"""Les demandes, et l'accord de l'utilisateur                (ACC-4 à ACC-14)

Ce qu'un modèle a demandé de changer attend ici. Accepter le fait, par la même
route que le geste à la main ; refuser le laisse tel quel. Une demande qui
échoue à l'accord, parce que le planning a bougé depuis, garde le motif de la
base.
"""

from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel, Field

from api import demandes
from api.securite import Authentifie

routeur = APIRouter(prefix="/demandes", tags=["Demandes"])

STATUTS = {"introuvable": status.HTTP_404_NOT_FOUND, "deja_decidee": status.HTTP_409_CONFLICT,
           "demande_expiree": status.HTTP_410_GONE}


class Lot(BaseModel):
    ids: list[int] = Field(min_length=1, max_length=30)


def _refus(refus: demandes.DemandeImpossible) -> HTTPException:
    return HTTPException(status_code=STATUTS.get(refus.code, status.HTTP_409_CONFLICT),
                         detail={"code": refus.code, "message": refus.motif})


@routeur.get("", summary="Mes demandes, en attente d'abord")
def lister(qui: Authentifie, en_attente: bool = False) -> list[dict]:
    return demandes.lister_pour(qui.id_utilisateur, en_attente)


@routeur.post("/{id_demande}/accepter", summary="Accepter une demande : elle se fait")
def accepter(id_demande: int, qui: Authentifie) -> dict:
    try:
        return demandes.accepter(qui.id_utilisateur, id_demande)
    except demandes.DemandeImpossible as refus:
        raise _refus(refus) from None


@routeur.post("/{id_demande}/refuser", summary="Refuser une demande : rien ne change")
def refuser(id_demande: int, qui: Authentifie) -> dict:
    try:
        return demandes.refuser(qui.id_utilisateur, id_demande)
    except demandes.DemandeImpossible as refus:
        raise _refus(refus) from None


@routeur.post("/accepter", summary="Accepter plusieurs demandes, dans l'ordre du dépôt")
def accepter_tout(lot: Lot, qui: Authentifie) -> list[dict]:
    """ACC-6 : une par une. Celle que la base refuse n'empêche pas les suivantes."""
    ordre = {d["id_demande"]: d["deposee_le"]
             for d in demandes.lister_pour(qui.id_utilisateur, limite=200)}
    rendus = []
    for id_demande in sorted(lot.ids, key=lambda i: (ordre.get(i) is None, ordre.get(i))):
        try:
            rendus.append(demandes.accepter(qui.id_utilisateur, id_demande)["demande"])
        except demandes.DemandeImpossible as refus:
            rendus.append({"id_demande": id_demande, "etat": "echouee",
                           "code": refus.code, "motif_echec": refus.motif})
    return rendus
