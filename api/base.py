"""Accès à PostgreSQL.

Pas d'ORM : les requêtes sont écrites à la main, et la logique métier vit dans
la base. L'API se contente de lire des vues et d'appeler des fonctions.
"""

from collections.abc import Iterator
from contextlib import contextmanager
from typing import Any

from psycopg import Connection
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

from api.config import configuration

_pool: ConnectionPool | None = None


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
    if _pool is None:
        demarrer_pool()
    assert _pool is not None
    with _pool.connection() as conn:
        yield conn


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
