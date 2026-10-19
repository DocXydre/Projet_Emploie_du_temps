"""Accès à PostgreSQL.

Pas d'ORM : les requêtes sont écrites à la main, et la logique métier vit dans
la base. L'API se contente de lire des vues et d'appeler des fonctions.
"""

from collections.abc import Iterator
from contextlib import contextmanager
from contextvars import ContextVar
from typing import Any

from psycopg import Connection
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

from api import operation
from api.config import configuration

_pool: ConnectionPool | None = None

# ACC-3 : la transaction d'un essai, que tout ce qui s'exécute dedans partage.
_essai: ContextVar[Connection | None] = ContextVar("essai", default=None)


def demarrer_pool() -> None:
    global _pool
    if _pool is None:
        _pool = ConnectionPool(
            configuration().url_base,
            min_size=1,
            max_size=8,
            kwargs={"row_factory": dict_row},
            open=True,
        )


def arreter_pool() -> None:
    global _pool
    if _pool is not None:
        _pool.close()
        _pool = None


@contextmanager
def connexion() -> Iterator[Connection]:
    essai = _essai.get()
    if essai is not None:
        # Dans un essai, tout passe par la même transaction, qui sera annulée.
        _dire_l_operation(essai)
        yield essai
        return
    if _pool is None:
        demarrer_pool()
    assert _pool is not None
    with _pool.connection() as conn:
        _dire_l_operation(conn)
        yield conn


@contextmanager
def transaction_annulee() -> Iterator[None]:
    """ACC-3 : jouer une action pour voir si la base l'accepte, sans rien garder.

    Tout ce qui s'exécute dans le bloc, routes et fonctions comprises, partage
    une seule transaction, annulée à la sortie, que l'action ait réussi ou non.
    """
    if _pool is None:
        demarrer_pool()
    assert _pool is not None
    with _pool.connection() as conn:
        jeton = _essai.set(conn)
        try:
            yield
        finally:
            _essai.reset(jeton)
            conn.rollback()


def _dire_l_operation(conn: Connection) -> None:
    """JRN-4 : dit à PostgreSQL de quelle action vient cette transaction.

    Les trois réglages ne valent que pour la transaction : une connexion rendue
    au pool ne garde rien de l'action précédente.
    """
    en_cours = operation.courante()
    if en_cours is None:
        return
    conn.execute(
        "SELECT set_config('planif.operation', %s, TRUE),"
        "       set_config('planif.acteur', %s, TRUE),"
        "       set_config('planif.origine', %s, TRUE)",
        (en_cours.identifiant, en_cours.acteur or "", en_cours.origine),
    )


def lister(requete: str, params: dict[str, Any] | None = None) -> list[dict]:
    with connexion() as conn, conn.cursor() as cur:
        cur.execute(requete, params or {})
        return cur.fetchall()


def un_seul(requete: str, params: dict[str, Any] | None = None) -> dict | None:
    with connexion() as conn, conn.cursor() as cur:
        cur.execute(requete, params or {})
        return cur.fetchone()


def executer(requete: str, params: dict[str, Any] | None = None) -> dict | None:
    """Requête modifiante. La transaction est validée à la sortie du contexte."""
    with connexion() as conn, conn.cursor() as cur:
        cur.execute(requete, params or {})
        if cur.description is None:
            return None
        return cur.fetchone()
