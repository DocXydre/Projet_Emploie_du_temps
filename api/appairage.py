"""Relier le bot d'administration au compte de l'administrateur        (ADM-5)

Une conversation Telegram ne connaît que son numéro : `/demarrer` suivi d'une
clé le relie au compte qui la porte, s'il administre le serveur.
"""

from __future__ import annotations

from api import sessions
from api.base import executer, un_seul


def appairer(cle_api: str, id_telegram: int) -> dict | None:
    """Associe une conversation Telegram au compte de l'administrateur du
    serveur, via sa clé d'API (ADM-5). Une clé d'un autre compte ne relie rien.

    La clé fait office de mot de passe : celle du compte, ou celle d'une
    session de l'appli (CNX-11). Un appairage existant est écrasé, ce qui
    permet de changer de téléphone.
    """
    compte = sessions.appelant_de(cle_api.strip())
    if compte is None or compte["role"] != "admin":
        return None
    return executer(
        """
        UPDATE utilisateur
           SET id_telegram = %(tg)s
         WHERE id_utilisateur = %(u)s
        RETURNING id_utilisateur, pseudo, role
        """,
        {"u": compte["id_utilisateur"], "tg": id_telegram},
    )


def compte_de(id_telegram: int) -> dict | None:
    return un_seul(
        """
        SELECT id_utilisateur, pseudo, role FROM utilisateur
         WHERE id_telegram = %(tg)s AND actif
        """,
        {"tg": id_telegram},
    )


def desappairer(id_telegram: int) -> bool:
    resultat = executer(
        "UPDATE utilisateur SET id_telegram = NULL WHERE id_telegram = %(tg)s RETURNING pseudo",
        {"tg": id_telegram},
    )
    return resultat is not None
