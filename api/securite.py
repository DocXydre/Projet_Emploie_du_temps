"""Authentification par clé d'API.

Pour deux utilisateurs sur un réseau local, les jetons à durée de vie et les
mécanismes de rafraîchissement sont du décor. Une clé longue par personne,
transmise dans un en-tête, suffit et se révoque en une requête SQL.
"""

from typing import Annotated

from fastapi import Depends, Header, HTTPException, Query, status
from pydantic import BaseModel

from api.base import lister, un_seul

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


CONTENUS = ("cours", "travail", "perso", "taches", "sport", "weekends")


class Abonnement(BaseModel):
    """Ce qu'un jeton d'URL ouvre : des personnes, et des familles de contenu."""

    id_calendrier: int | None
    libelle: str
    id_utilisateur: int
    pseudo: str
    role: str
    personnes: list[int]
    contenus: list[str]


def _comptes(pseudos: list[str], moi: int) -> list[int]:
    """Traduit « lorette », « moi » ou « tous » en identifiants de comptes."""
    voulus, tous = [], False
    for pseudo in pseudos:
        if pseudo in ("tous", "nous", "toutes"):
            tous = True
        elif pseudo == "moi":
            voulus.append(moi)

    lignes = lister(
        "SELECT id_utilisateur, pseudo FROM utilisateur WHERE actif ORDER BY id_utilisateur"
    )
    connus = {ligne["pseudo"]: ligne["id_utilisateur"] for ligne in lignes}

    if tous:
        return list(connus.values())

    for pseudo in pseudos:
        if pseudo in ("moi", "tous", "nous", "toutes"):
            continue
        if pseudo not in connus:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail={"code": "personne_inconnue",
                        "message": f"Aucun compte actif ne s'appelle « {pseudo} »"},
            )
        voulus.append(connus[pseudo])

    return list(dict.fromkeys(voulus))


def _liste(valeur: str | None) -> list[str]:
    """« cours,sport » ou « cours sport » : les deux se lisent."""
    if not valeur:
        return []
    return [morceau.strip().lower()
            for morceau in valeur.replace(" ", ",").split(",") if morceau.strip()]


def abonnement_par_url(
    cle: Annotated[str | None, Query()] = None,
    qui: Annotated[str | None, Query()] = None,
    quoi: Annotated[str | None, Query()] = None,
) -> Abonnement:
    """Le jeton d'un compte, ou celui d'un calendrier composé (NOT-8).

    Les paramètres `qui` et `quoi` ne valent que pour un jeton de compte :
    celui d'un calendrier composé dit déjà ce qu'il montre, et le laisser
    s'élargir dans l'URL reviendrait à donner tout le planning à qui n'a reçu
    que les cours.
    """
    if not cle:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"code": "jeton_absent",
                    "message": "Paramètre « cle » requis dans l'URL d'abonnement"},
        )

    ligne = un_seul("SELECT * FROM abonnement_du_jeton(%(jeton)s)", {"jeton": cle})
    if ligne is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"code": "jeton_invalide",
                    "message": "Abonnement inconnu ou renouvelé depuis"},
        )

    abonnement = Abonnement(**ligne)
    if abonnement.id_calendrier is not None:
        return abonnement

    if qui:
        abonnement.personnes = _comptes(_liste(qui), abonnement.id_utilisateur)
    if quoi:
        demandes = _liste(quoi)
        inconnus = [c for c in demandes if c not in CONTENUS]
        if inconnus:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail={"code": "contenu_inconnu",
                        "message": f"Contenu inconnu : {', '.join(inconnus)}. "
                                   f"Au choix : {', '.join(CONTENUS)}"},
            )
        abonnement.contenus = demandes

    return abonnement


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
Abonne = Annotated[Abonnement, Depends(abonnement_par_url)]
