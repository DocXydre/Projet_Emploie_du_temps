"""Authentification par clé d'API.

Pour deux utilisateurs sur un réseau local, les jetons à durée de vie et les
mécanismes de rafraîchissement sont du décor. Une clé longue par personne,
transmise dans un en-tête, suffit et se révoque en une requête SQL.
"""

from typing import Annotated

from fastapi import Depends, Header, HTTPException, Query, status
from pydantic import BaseModel

from api.base import un_seul

EN_TETE = "X-Cle-Api"


class Appelant(BaseModel):
    id_utilisateur: int
    pseudo: str
    role: str

    @property
    def est_admin(self) -> bool:
        return self.role == "admin"


def _par_cle(cle: str | None) -> Appelant:
    if not cle:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"code": "cle_absente", "message": f"En-tête {EN_TETE} requis"},
        )

    ligne = un_seul(
        """
        SELECT id_utilisateur, pseudo, role
          FROM utilisateur
         WHERE cle_api = %(cle)s AND actif
        """,
        {"cle": cle},
    )
    if ligne is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"code": "cle_invalide", "message": "Clé d'API inconnue ou compte inactif"},
        )
    return Appelant(**ligne)


def appelant(x_cle_api: Annotated[str | None, Header(alias=EN_TETE)] = None) -> Appelant:
    return _par_cle(x_cle_api)


def appelant_par_url(cle: Annotated[str | None, Query()] = None) -> Appelant:
    """Variante pour le flux iCalendar.

    Les applications de calendrier ne savent pas envoyer d'en-tête personnalisé :
    le jeton passe donc dans l'URL. Et comme cette URL est conservée en clair
    par le téléphone, recopiée dans ses sauvegardes et rejouée à chaque
    rafraîchissement, ce n'est pas la clé d'API qui y voyage mais un jeton
    distinct, qui ne donne que la lecture du planning.
    """
    if not cle:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"code": "jeton_absent",
                    "message": "Paramètre « cle » requis dans l'URL d'abonnement"},
        )

    ligne = un_seul(
        """
        SELECT id_utilisateur, pseudo, role
          FROM utilisateur
         WHERE jeton_calendrier = %(jeton)s AND actif
        """,
        {"jeton": cle},
    )
    if ligne is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"code": "jeton_invalide",
                    "message": "Abonnement inconnu ou renouvelé depuis"},
        )
    return Appelant(**ligne)


def exiger_admin(qui: Annotated[Appelant, Depends(appelant)]) -> Appelant:
    if not qui.est_admin:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail={"code": "droits_insuffisants", "message": "Réservé à l'administrateur"},
        )
    return qui


Authentifie = Annotated[Appelant, Depends(appelant)]
Administrateur = Annotated[Appelant, Depends(exiger_admin)]
