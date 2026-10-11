"""Se connecter depuis l'appli : pseudo et mot de passe       (CNX-1 à CNX-4)

`POST /connexion` est la seule route ouverte sans clé. Elle rend la clé d'API du
compte, que l'appli garde dans le trousseau et envoie ensuite comme avant, dans
l'en-tête X-Cle-Api. Rien d'autre ne change pour le reste de l'API.
"""

from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel, Field

from api import mot_de_passe
from api.securite import Authentifie

routeur = APIRouter(tags=["Connexion"])


class Identifiants(BaseModel):
    pseudo: str = Field(min_length=1, max_length=64)
    mot_de_passe: str = Field(min_length=1, max_length=200)


class NouveauMotDePasse(BaseModel):
    mot_de_passe: str = Field(max_length=200)


@routeur.post("/connexion", summary="Pseudo et mot de passe : rend la clé d'API")
def connexion(identifiants: Identifiants) -> dict:
    try:
        compte = mot_de_passe.connecter(identifiants.pseudo, identifiants.mot_de_passe)
    except mot_de_passe.CompteBloque:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail={"code": "trop_d_essais",
                    "message": "Trop d'essais. Réessaie dans un quart d'heure."}) from None
    if compte is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"code": "identifiants_invalides",
                    "message": "Pseudo ou mot de passe incorrect."})
    return compte


@routeur.put("/mot-de-passe", summary="Choisir ou changer son mot de passe")
def changer_mot_de_passe(qui: Authentifie, nouveau: NouveauMotDePasse) -> dict:
    try:
        mot_de_passe.choisir(qui.id_utilisateur, nouveau.mot_de_passe)
    except mot_de_passe.MotDePasseRefuse as refus:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={"code": "mot_de_passe_refuse", "message": str(refus)}) from None
    return {"fait": True}
