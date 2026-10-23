"""Les sessions : une clé par appareil, gardée en empreinte        (CNX-11, CNX-12)

Chaque connexion de l'appli, par mot de passe, par Apple ou en rejoignant le
foyer, ouvre une session : une clé à elle, montrée une seule fois, dont la base
ne garde que l'empreinte SHA-256. Se déconnecter la révoque, sans toucher aux
autres appareils.

La clé du compte, celle de `utilisateur`, ouvre toujours l'API : les iPhones
connectés avant les sessions la gardent dans leur trousseau, et les scripts
comme le bot d'administration s'en servent. Elle aussi n'est plus gardée
qu'en empreinte.

SHA-256 suffit ici, sans sel ni scrypt : une clé tirée au hasard sur 288 bits
ne se devine pas, contrairement à un mot de passe.
"""

import hashlib
import secrets

from api.base import executer, lister, un_seul


def empreinte(cle: str) -> str:
    return hashlib.sha256(cle.encode("utf-8")).hexdigest()


def ouvrir(id_utilisateur: int, nom: str | None = None) -> str:
    """CNX-11 : une session neuve. Sa clé n'est rendue qu'ici."""
    cle = secrets.token_urlsafe(36)
    executer(
        """INSERT INTO session_appareil (id_utilisateur, empreinte, nom)
           VALUES (%(u)s, %(e)s, NULLIF(btrim(left(%(n)s, 80)), ''))""",
        {"u": id_utilisateur, "e": empreinte(cle), "n": nom})
    return cle


def appelant_de(cle: str) -> dict | None:
    """Le compte actif qu'ouvre cette clé, et sa session s'il s'agit d'une session.

    Une session révoquée, ou celle d'un compte mis en pause, n'ouvre rien.
    """
    trace = empreinte(cle)
    ligne = un_seul(
        """
        SELECT u.id_utilisateur, u.pseudo, u.role, s.id_session
          FROM session_appareil s
          JOIN utilisateur u ON u.id_utilisateur = s.id_utilisateur
         WHERE s.empreinte = %(e)s AND s.revoquee_le IS NULL AND u.actif
        UNION ALL
        SELECT id_utilisateur, pseudo, role, NULL
          FROM utilisateur
         WHERE empreinte_cle_api = %(e)s AND actif
        LIMIT 1
        """,
        {"e": trace})
    if ligne is not None and ligne["id_session"] is not None:
        # À l'heure près : chaque appel n'a pas à écrire en base.
        executer("""UPDATE session_appareil SET vue_le = now()
                     WHERE id_session = %(s)s AND vue_le < now() - INTERVAL '1 hour'""",
                 {"s": ligne["id_session"]})
    return ligne


def lister_sessions(id_utilisateur: int, courante: int | None) -> list[dict]:
    return lister(
        """SELECT id_session, nom, ouverte_le, vue_le,
                  id_session = %(c)s AS courante
             FROM session_appareil
            WHERE id_utilisateur = %(u)s AND revoquee_le IS NULL
            ORDER BY vue_le DESC""",
        {"u": id_utilisateur, "c": courante})


def revoquer(id_utilisateur: int, id_session: int) -> bool:
    """CNX-6 : la clé de cette session ne répond plus. Seulement les siennes."""
    return executer(
        """UPDATE session_appareil SET revoquee_le = now()
            WHERE id_session = %(s)s AND id_utilisateur = %(u)s AND revoquee_le IS NULL
        RETURNING id_session""",
        {"s": id_session, "u": id_utilisateur}) is not None
