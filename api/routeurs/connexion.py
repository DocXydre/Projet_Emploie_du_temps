"""Se connecter depuis l'appli : pseudo et mot de passe, ou Apple  (CNX-1 à CNX-9)

`POST /connexion` et `POST /connexion/apple` sont ouvertes sans clé. Elles rendent
la clé d'API du compte, que l'appli garde dans le trousseau et envoie ensuite
comme avant, dans l'en-tête X-Cle-Api. Rien d'autre ne change pour le reste de
l'API.
"""

from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel, Field

from api import identifiant_apple, mot_de_passe
from api.securite import Authentifie

routeur = APIRouter(tags=["Connexion"])


class Identifiants(BaseModel):
    pseudo: str = Field(min_length=1, max_length=64)
    mot_de_passe: str = Field(min_length=1, max_length=200)
    # CNX-8 : le jeton de « Se connecter avec Apple », à relier au compte.
    jeton_apple: str | None = Field(default=None, max_length=5000)


class JetonApple(BaseModel):
    jeton: str = Field(min_length=1, max_length=5000)


class NouveauMotDePasse(BaseModel):
    mot_de_passe: str = Field(max_length=200)


def identifiant_du_jeton(jeton: str) -> str:
    """CNX-7 : l'identifiant Apple du jeton, ou 401."""
    try:
        return identifiant_apple.verifier(jeton)
    except identifiant_apple.JetonRefuse:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"code": "apple_refuse",
                    "message": "Apple n'a pas confirmé qui tu es. Réessaie."}) from None


@routeur.post("/connexion", summary="Pseudo et mot de passe : rend la clé d'API")
def connexion(identifiants: Identifiants) -> dict:
    # Vérifié d'abord : un jeton refusé ne compte pas comme un échec du mot de passe.
    apple = identifiant_du_jeton(identifiants.jeton_apple) if identifiants.jeton_apple else None
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
    id_utilisateur = compte.pop("id_utilisateur")
    if apple:
        identifiant_apple.relier(id_utilisateur, apple)
    return compte


@routeur.post("/connexion/apple", summary="Se connecter avec Apple : rend la clé d'API")
def connexion_apple(apple: JetonApple) -> dict:
    """CNX-7 : un identifiant Apple déjà relié ouvre son compte. Sinon, l'appli
    demande une fois le pseudo et le mot de passe, et les envoie avec le jeton."""
    compte = identifiant_apple.compte(identifiant_du_jeton(apple.jeton))
    if compte is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"code": "apple_inconnu",
                    "message": "Ton identifiant Apple n'est relié à aucun compte. "
                               "Connecte-toi une fois avec ton pseudo et ton mot de passe : "
                               "il le sera."})
    return compte


@routeur.get("/moi/apple", summary="Mon compte est-il relié à un identifiant Apple ?")
def etat_apple(qui: Authentifie) -> dict:
    return {"relie": identifiant_apple.relie(qui.id_utilisateur)}


@routeur.put("/moi/apple", summary="Relier mon compte à mon identifiant Apple")
def relier_apple(qui: Authentifie, apple: JetonApple) -> dict:
    identifiant_apple.relier(qui.id_utilisateur, identifiant_du_jeton(apple.jeton))
    return {"relie": True}


@routeur.delete("/moi/apple", summary="Ne plus se connecter avec Apple")
def delier_apple(qui: Authentifie) -> dict:
    identifiant_apple.delier(qui.id_utilisateur)
    return {"relie": False}


@routeur.put("/mot-de-passe", summary="Choisir ou changer son mot de passe")
def changer_mot_de_passe(qui: Authentifie, nouveau: NouveauMotDePasse) -> dict:
    try:
        mot_de_passe.choisir(qui.id_utilisateur, nouveau.mot_de_passe)
    except mot_de_passe.MotDePasseRefuse as refus:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={"code": "mot_de_passe_refuse", "message": str(refus)}) from None
    return {"fait": True}
