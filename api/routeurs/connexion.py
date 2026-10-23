"""Se connecter depuis l'appli : pseudo et mot de passe, ou Apple  (CNX-1 à CNX-9)

`POST /connexion` et `POST /connexion/apple` sont ouvertes sans clé. Elles
ouvrent une session et rendent sa clé, que l'appli garde dans le trousseau et
envoie ensuite dans l'en-tête X-Cle-Api, comme celle du compte (CNX-11). Se
déconnecter révoque la session, et seulement elle.
"""

from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel, Field

from api import identifiant_apple, mot_de_passe, sessions
from api.securite import Authentifie

routeur = APIRouter(tags=["Connexion"])


class Identifiants(BaseModel):
    pseudo: str = Field(min_length=1, max_length=64)
    mot_de_passe: str = Field(min_length=1, max_length=200)
    # CNX-8 : le jeton de « Se connecter avec Apple », à relier au compte.
    jeton_apple: str | None = Field(default=None, max_length=5000)
    # CNX-11 : le nom de l'iPhone, pour reconnaître ses sessions.
    appareil: str | None = Field(default=None, max_length=80)


class JetonApple(BaseModel):
    jeton: str = Field(min_length=1, max_length=5000)
    appareil: str | None = Field(default=None, max_length=80)


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


@routeur.post("/connexion", summary="Pseudo et mot de passe : ouvre une session")
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
    if apple:
        identifiant_apple.relier(compte["id_utilisateur"], apple)
    return _session(compte, identifiants.appareil)


def _session(compte: dict, appareil: str | None) -> dict:
    """CNX-11 : le pseudo, et la clé d'une session neuve."""
    return {"pseudo": compte["pseudo"],
            "cle_api": sessions.ouvrir(compte["id_utilisateur"], appareil)}


@routeur.post("/connexion/apple", summary="Se connecter avec Apple : ouvre une session")
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
    return _session(compte, apple.appareil)


@routeur.get("/moi/sessions", summary="Les appareils connectés à mon compte")
def mes_sessions(qui: Authentifie) -> list[dict]:
    """CNX-11 : les sessions ouvertes, la plus récemment vue d'abord. `courante`
    marque celle de l'appel."""
    return sessions.lister_sessions(qui.id_utilisateur, qui.id_session)


@routeur.delete("/moi/session", summary="Se déconnecter : révoque la clé de cet appareil")
def fermer_ma_session(qui: Authentifie) -> dict:
    """CNX-6 : la clé envoyée ne répond plus. La clé du compte, elle, ne se révoque
    pas ainsi : elle sert aussi aux autres appareils et aux scripts."""
    if qui.id_session is None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={"code": "cle_du_compte",
                    "message": "Cette clé est celle du compte, pas celle d'une session : "
                               "elle reste valable."})
    sessions.revoquer(qui.id_utilisateur, qui.id_session)
    return {"revoquee": qui.id_session}


@routeur.delete("/moi/sessions/{id_session}", summary="Déconnecter un autre appareil")
def fermer_une_session(id_session: int, qui: Authentifie) -> dict:
    if not sessions.revoquer(qui.id_utilisateur, id_session):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"code": "session_inconnue",
                    "message": "Cette session n'existe pas, est déjà fermée, ou n'est pas "
                               "la tienne"})
    return {"revoquee": id_session}


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
