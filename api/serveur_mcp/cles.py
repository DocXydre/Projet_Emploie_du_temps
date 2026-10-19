"""Les clés des clients MCP, et leurs sessions               (MCP-2, MCP-10)

Une clé par client, créée dans Réglages et nommée (« Claude Code du Mac »).
Elle n'ouvre que /mcp, se révoque seule, et n'est montrée qu'une fois : seule
son empreinte est gardée. Une clé copiée dans la configuration d'un portable
ne donne donc pas la clé de l'appli, et se coupe sans déconnecter le téléphone.

Le transport est sans état : chaque requête HTTP arrive seule. Une session
regroupe ce qu'un client a fait d'une traite, jusqu'à trente minutes de
silence. Elle porte le numéro d'opération sous lequel s'écrit tout ce qu'elle
fait (JRN-4).
"""

import hashlib
import secrets
from dataclasses import dataclass
from uuid import uuid4

from psycopg.types.json import Jsonb

from api.base import executer, lister, un_seul

PREFIXE = "hal_"

# Au-delà, un nouvel appel ouvre une nouvelle session.
SILENCE_MINUTES = 30

# Le déroulé d'une session garde ses derniers outils, pas tous.
DEROULE_MAX = 200


@dataclass(frozen=True)
class Porteur:
    """Qui est derrière une requête MCP : le compte, et la clé de son client."""

    id_utilisateur: int
    pseudo: str
    id_cle: int
    nom_cle: str


def empreinte(cle: str) -> str:
    return hashlib.sha256(cle.encode("utf-8")).hexdigest()


def creer(id_utilisateur: int, nom: str) -> dict:
    """Une clé neuve. Elle n'est rendue qu'ici : la base n'en garde que l'empreinte."""
    cle = PREFIXE + secrets.token_urlsafe(32)
    ligne = executer(
        """INSERT INTO cle_mcp (id_utilisateur, nom, empreinte)
           VALUES (%(u)s, btrim(%(n)s), %(e)s)
           RETURNING id_cle, nom, cree_le""",
        {"u": id_utilisateur, "n": nom, "e": empreinte(cle)})
    assert ligne is not None
    return {**ligne, "cle": cle}


def lister_cles(id_utilisateur: int) -> list[dict]:
    return lister(
        """SELECT id_cle, nom, cree_le, dernier_usage, revoquee_le
             FROM cle_mcp WHERE id_utilisateur = %(u)s
            ORDER BY revoquee_le IS NOT NULL, cree_le DESC""",
        {"u": id_utilisateur})


def revoquer(id_utilisateur: int, id_cle: int) -> bool:
    """Une clé révoquée n'ouvre plus rien, tout de suite. Ses sessions restent lisibles."""
    ligne = executer(
        """UPDATE cle_mcp SET revoquee_le = now()
            WHERE id_cle = %(c)s AND id_utilisateur = %(u)s AND revoquee_le IS NULL
        RETURNING id_cle""",
        {"c": id_cle, "u": id_utilisateur})
    return ligne is not None


def porteur(cle: str | None) -> Porteur | None:
    """Le compte d'une clé vivante, d'un compte actif. Rien pour tout le reste."""
    if not cle or not cle.startswith(PREFIXE):
        return None
    ligne = executer(
        """UPDATE cle_mcp k SET dernier_usage = now()
             FROM utilisateur u
            WHERE k.empreinte = %(e)s AND k.revoquee_le IS NULL
              AND u.id_utilisateur = k.id_utilisateur AND u.actif
        RETURNING u.id_utilisateur, u.pseudo, k.id_cle, k.nom AS nom_cle""",
        {"e": empreinte(cle)})
    return Porteur(**ligne) if ligne else None


def ouvrir_session(id_cle: int, client: str) -> dict:
    """Une session neuve : le client vient de se présenter."""
    ligne = executer(
        """INSERT INTO session_mcp (id_cle, client, operation)
           VALUES (%(c)s, left(btrim(%(n)s), 60), %(o)s)
           RETURNING id_session, client, operation""",
        {"c": id_cle, "n": client or "client inconnu", "o": uuid4().hex[:16]})
    assert ligne is not None
    return ligne


def session_de(id_cle: int, client: str) -> dict:
    """La session en cours de ce client, ou une neuve après trente minutes de silence."""
    ligne = un_seul(
        """SELECT id_session, client, operation FROM session_mcp
            WHERE id_cle = %(c)s
              AND dernier_appel > now() - make_interval(mins => %(m)s)
            ORDER BY dernier_appel DESC LIMIT 1""",
        {"c": id_cle, "m": SILENCE_MINUTES})
    return ligne or ouvrir_session(id_cle, client)


def noter_appel(id_session, outil: str, debut_du_resultat: str, refus: bool) -> None:
    """MCP-10 : un outil de plus au déroulé, avec le début de ce qu'il a rendu."""
    executer(
        """UPDATE session_mcp
              SET appels = appels + 1, dernier_appel = now(),
                  deroule = (SELECT COALESCE(jsonb_agg(x ORDER BY n), '[]')
                               FROM jsonb_array_elements(deroule || %(d)s)
                                    WITH ORDINALITY AS t(x, n)
                              WHERE n > jsonb_array_length(deroule) + 1 - %(max)s)
            WHERE id_session = %(s)s""",
        {"s": id_session, "max": DEROULE_MAX,
         "d": Jsonb([{"outil": outil, "refus": refus,
                      "resultat": debut_du_resultat[:200]}])})


def sessions(id_utilisateur: int, limite: int = 20) -> list[dict]:
    return lister(
        """SELECT s.id_session, s.client, k.nom AS cle, s.debut, s.dernier_appel, s.appels
             FROM session_mcp s JOIN cle_mcp k ON k.id_cle = s.id_cle
            WHERE k.id_utilisateur = %(u)s
            ORDER BY s.dernier_appel DESC LIMIT %(l)s""",
        {"u": id_utilisateur, "l": limite})
