"""Les fournisseurs du modèle, dans Réglages, Intelligence      (FOU-17 à FOU-19)

Brancher son abonnement Claude (le jeton de `claude setup-token`), une clé
d'API, ou son compte Google pour Gemini CLI ; les ranger, en couper un, le
retirer, régler le plafond de l'API. Un secret collé est essayé par un appel
minimal avant d'être gardé.
"""

from typing import Literal

from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel, Field

from api.coach import course, course_gemini, fournisseurs, modele
from api.config import configuration
from api.securite import Authentifie

routeur = APIRouter(prefix="/moi/fournisseurs", tags=["Fournisseurs du modèle"])

TypeFournisseur = Literal["claude_code", "api", "gemini_cli"]


class Branchement(BaseModel):
    secret: str | None = Field(default=None, min_length=20, max_length=8000,
                               description="Le jeton de `claude setup-token`, une clé "
                                           "d'API, ou pour Gemini CLI le contenu de "
                                           "~/.gemini/oauth_creds.json (ou une clé Gemini). "
                                           "Vide pour l'API : la clé du serveur, pour son "
                                           "administrateur seulement")
    plafond: float | None = Field(default=None, gt=0, le=1000,
                                  description="FOU-7 : le plafond mensuel de l'API, en $")


class Ordre(BaseModel):
    ordre: list[TypeFournisseur] = Field(min_length=1)


class Plafond(BaseModel):
    plafond: float = Field(gt=0, le=1000)


def _refus(code: str, message: str, statut: int = 422):
    return HTTPException(status_code=statut, detail={"code": code, "message": message})


def _essayer(type_: str, secret: str) -> None:
    """FOU-18 : un appel minimal. Un jeton refusé ne se garde pas."""
    try:
        if type_ == "claude_code":
            course.essayer(secret)
        elif type_ == "gemini_cli":
            course_gemini.essayer(secret)
        else:
            conf = configuration()
            modele.ecrire("Réponds seulement OK.", "OK ?",
                          conf.coach_modele_aiguillage or conf.coach_modele, 5, 30.0,
                          cle=secret)
    except fournisseurs.Indisponible as erreur:
        if erreur.nature == "jeton" and type_ == "gemini_cli":
            raise _refus("jeton_refuse", erreur.motif) from None
        if erreur.nature == "jeton":
            raise _refus("jeton_refuse", "Ce jeton est refusé : recopie-le en entier, "
                         "ou refais `claude setup-token`.") from None
        if erreur.nature != "limite":
            raise _refus("essai_impossible", f"Essai impossible : {erreur.motif}",
                         status.HTTP_502_BAD_GATEWAY) from None
    except modele.ModeleInjoignable as erreur:
        if erreur.nature == "jeton":
            raise _refus("cle_refusee", "Cette clé d'API est refusée.") from None
        if erreur.nature != "limite":
            raise _refus("essai_impossible", f"Essai impossible : {erreur}",
                         status.HTTP_502_BAD_GATEWAY) from None


@routeur.get("", summary="Mes fournisseurs, dans l'ordre, et la dépense API du mois")
def lister(qui: Authentifie) -> dict:
    return fournisseurs.lister_pour(qui.id_utilisateur)


@routeur.put("/ordre", summary="Ranger mes fournisseurs")
def ranger(ordre: Ordre, qui: Authentifie) -> dict:
    fournisseurs.ranger(qui.id_utilisateur, list(dict.fromkeys(ordre.ordre)))
    return fournisseurs.lister_pour(qui.id_utilisateur)


@routeur.put("/api/plafond", summary="Régler le plafond mensuel de l'API")
def regler_plafond(plafond: Plafond, qui: Authentifie) -> dict:
    if not fournisseurs.regler_plafond(qui.id_utilisateur, plafond.plafond):
        raise _refus("fournisseur_absent", "Branche d'abord une clé d'API",
                     status.HTTP_404_NOT_FOUND)
    return fournisseurs.lister_pour(qui.id_utilisateur)


@routeur.put("/{type_}", summary="Brancher mon abonnement Claude, une clé d'API, ou Gemini CLI")
def brancher(type_: TypeFournisseur, branchement: Branchement, qui: Authentifie) -> dict:
    secret = (branchement.secret or "").strip() or None
    if type_ == "gemini_cli" and not fournisseurs.gemini_propose():
        # FOU-17 : pas avant que les scénarios du coach soient passés avec lui.
        raise _refus("gemini_pas_valide", "Gemini CLI n'est pas encore validé sur ce serveur",
                     status.HTTP_409_CONFLICT)
    if secret is None and type_ == "gemini_cli":
        raise _refus("jeton_absent", "Colle le contenu de ~/.gemini/oauth_creds.json")
    if secret is None and type_ == "claude_code":
        raise _refus("jeton_absent", "Colle le jeton que donne `claude setup-token`")
    if secret is None and not qui.est_admin:
        # FOU-2 : la clé du serveur est celle de son administrateur.
        raise _refus("cle_absente", "Colle ta clé d'API")
    if secret is None and not configuration().anthropic_api_key:
        raise _refus("cle_du_serveur_absente", "Le serveur n'a pas de clé d'API")
    if secret is not None and not configuration().hal_cle_chiffrement.strip():
        raise _refus("chiffrement_absent",
                     "Le serveur ne peut pas garder de secret : HAL_CLE_CHIFFREMENT manque "
                     "dans son .env", status.HTTP_503_SERVICE_UNAVAILABLE)
    if secret is not None:
        _essayer(type_, secret)
    fournisseurs.brancher(qui.id_utilisateur, type_, secret, branchement.plafond)
    return fournisseurs.lister_pour(qui.id_utilisateur)


@routeur.post("/{type_}/couper", summary="Sortir un fournisseur de la chaîne, sans le retirer")
def couper(type_: TypeFournisseur, qui: Authentifie) -> dict:
    if not fournisseurs.changer_etat(qui.id_utilisateur, type_, coupe=True):
        raise _refus("fournisseur_absent", "Ce fournisseur n'est pas branché",
                     status.HTTP_404_NOT_FOUND)
    return fournisseurs.lister_pour(qui.id_utilisateur)


@routeur.post("/{type_}/reprendre", summary="Remettre un fournisseur coupé dans la chaîne")
def reprendre(type_: TypeFournisseur, qui: Authentifie) -> dict:
    if not fournisseurs.changer_etat(qui.id_utilisateur, type_, coupe=False):
        raise _refus("fournisseur_absent", "Ce fournisseur n'est pas coupé",
                     status.HTTP_404_NOT_FOUND)
    return fournisseurs.lister_pour(qui.id_utilisateur)


@routeur.delete("/{type_}", summary="Retirer un fournisseur et effacer son secret")
def retirer(type_: TypeFournisseur, qui: Authentifie) -> dict:
    if not fournisseurs.retirer(qui.id_utilisateur, type_):
        raise _refus("fournisseur_absent", "Ce fournisseur n'est pas branché",
                     status.HTTP_404_NOT_FOUND)
    return fournisseurs.lister_pour(qui.id_utilisateur)
