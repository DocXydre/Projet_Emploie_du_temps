"""Trajets en train : quand partir, à quelle heure, et le ménage qui suit.

Les horaires viennent de la SNCF. Comme pour les flux iCalendar, une réponse
déjà obtenue peut être injectée : c'est ce qui permet de vérifier tout le
parcours sans dépendre du réseau ni d'un jeton.
"""

import base64

from fastapi import APIRouter, Body, HTTPException, status
from pydantic import BaseModel

from api import billets
from api import trajets as service
from api.collecteurs.courriel import BoiteIndisponible
from api.collecteurs.sncf import TrajetImpossible
from api.securite import Administrateur, Authentifie

routeur = APIRouter(prefix="/trajets", tags=["Trajets"])


class DemandeRetenue(BaseModel):
    id_aller: int
    id_retour: int | None = None


def _traduire(erreur: TrajetImpossible) -> HTTPException:
    statuts = {
        "jeton_absent": status.HTTP_503_SERVICE_UNAVAILABLE,
        "jeton_refuse": status.HTTP_503_SERVICE_UNAVAILABLE,
        "injoignable": status.HTTP_502_BAD_GATEWAY,
        "introuvable": status.HTTP_404_NOT_FOUND,
    }
    return HTTPException(
        status_code=statuts.get(erreur.code, status.HTTP_502_BAD_GATEWAY),
        detail={"code": erreur.code, "message": erreur.message},
    )


@routeur.get("/propositions", summary="Week-ends repérés en attente de réponse")
def lister_propositions(qui: Authentifie) -> list[dict]:
    from api import propositions

    return propositions.en_attente(qui.id_utilisateur)


@routeur.post("/propositions/tour", summary="Repérer, annoncer, relancer")
def tour(qui: Administrateur) -> dict:
    from api import propositions

    return propositions.tour_de_ronde(qui.id_utilisateur)


@routeur.delete("/propositions/{id_proposition}", summary="Décliner un week-end")
def ecarter(id_proposition: int, qui: Authentifie) -> dict:
    from api import propositions

    ecartee = propositions.ecarter(id_proposition)
    if ecartee is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"code": "introuvable",
                    "message": f"Proposition {id_proposition} inconnue ou déjà tranchée"},
        )
    return ecartee


@routeur.get("/fenetres", summary="Creux assez longs pour partir")
def lister_fenetres(qui: Authentifie, jours: int | None = None,
                    heures: int | None = None) -> list[dict]:
    return service.fenetres(qui.id_utilisateur, jours, heures)


@routeur.get("", summary="Trajets retenus à venir")
def lister_retenus(qui: Authentifie) -> list[dict]:
    return service.trajets_retenus(qui.id_utilisateur)


@routeur.post("/aller", summary="Proposer des horaires de départ")
def aller(qui: Authentifie, rang: int = 1,
          charge: dict | None = Body(default=None)) -> dict:
    try:
        return service.proposer_aller(qui.id_utilisateur, rang, charge)
    except TrajetImpossible as erreur:
        raise _traduire(erreur) from erreur


@routeur.post("/retour", summary="Proposer des horaires de retour")
def retour(qui: Authentifie, aller: int,
           charge: dict | None = Body(default=None)) -> dict:
    try:
        return service.proposer_retour(aller, charge)
    except TrajetImpossible as erreur:
        raise _traduire(erreur) from erreur


@routeur.post("/retenir", status_code=status.HTTP_201_CREATED,
              summary="Retenir un aller-retour et déclarer l'absence")
def retenir(demande: DemandeRetenue, qui: Authentifie) -> dict:
    return service.retenir(demande.id_aller, demande.id_retour)


@routeur.delete("/absence/{id_absence}", summary="Annuler un trajet retenu")
def annuler(id_absence: int, qui: Authentifie) -> dict:
    replacees = service.oublier(id_absence)
    return {"occurrences_replacees": replacees}


# ---------------------------------------------------------------------------
# Billets lus dans la boîte
# ---------------------------------------------------------------------------

class DemandeReleve(BaseModel):
    """Courriels bruts encodés en base64, pour rejouer une boîte sans IMAP.

    Le même chemin de code sert à la relève réelle et aux tests : sans cela, ce
    qui tourne la nuit finirait par diverger de ce qu'on vérifie.
    """

    messages: list[str]


@routeur.post("/courriels", summary="Relever les confirmations d'achat")
def relever(qui: Administrateur, demande: DemandeReleve | None = Body(default=None)) -> dict:
    bruts = None
    if demande is not None:
        try:
            bruts = [base64.b64decode(m) for m in demande.messages]
        except (ValueError, TypeError) as erreur:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail={"code": "base64_invalide", "message": str(erreur)},
            ) from erreur

    try:
        return billets.relever(qui.id_utilisateur, bruts)
    except BoiteIndisponible as erreur:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail={"code": erreur.code, "message": erreur.message},
        ) from erreur


@routeur.get("/courriels/a-revoir", summary="Courriels SNCF non exploités")
def a_revoir(qui: Authentifie, limite: int = 10) -> list[dict]:
    return billets.a_revoir(limite)


@routeur.delete("/courriels/a-revoir", summary="Réessayer les courriels ratés")
def reessayer(qui: Administrateur) -> dict:
    """Oublie les courriels non exploités, pour que la relève les relise.

    À lancer après chaque correction du lecteur : sans cela, les courriels sur
    lesquels il avait échoué resteraient marqués comme vus, et la correction
    n'aurait aucun effet visible.
    """
    return {"oublies": billets.oublier_les_rates()}
