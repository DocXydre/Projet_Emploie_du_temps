"""Traduction des erreurs SQL en réponses HTTP.

La base porte les règles métier : quand elle refuse une opération, c'est une
erreur métier, pas un bug. On traduit donc ses codes d'erreur PostgreSQL en
statuts HTTP plutôt que de laisser sortir un 500.
"""

import logging

import psycopg
from fastapi import Request, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException

LOG = logging.getLogger(__name__)

# Codes SQLSTATE levés volontairement par les fonctions et triggers.
CORRESPONDANCES = {
    "23514": (status.HTTP_409_CONFLICT, "regle_metier"),        # check_violation
    "23P01": (status.HTTP_409_CONFLICT, "chevauchement"),       # exclusion_violation
    "23505": (status.HTTP_409_CONFLICT, "doublon"),             # unique_violation
    "23503": (status.HTTP_400_BAD_REQUEST, "reference_absente"),  # foreign_key_violation
    "42501": (status.HTTP_403_FORBIDDEN, "droits_insuffisants"),  # insufficient_privilege
    "P0002": (status.HTTP_404_NOT_FOUND, "introuvable"),        # no_data_found
}


def message_lisible(erreur: psycopg.Error) -> str:
    """Le message des RAISE EXCEPTION est déjà écrit pour être lu par un humain."""
    diag = erreur.diag
    return (diag.message_primary or str(erreur)).strip()


async def gerer_erreur_sql(requete: Request, erreur: Exception) -> JSONResponse:
    assert isinstance(erreur, psycopg.Error)
    code_sql = erreur.sqlstate or ""
    inconnu = (status.HTTP_500_INTERNAL_SERVER_ERROR, "erreur_interne")
    statut, code = CORRESPONDANCES.get(code_sql, inconnu)

    if statut >= 500:
        LOG.exception("Erreur SQL inattendue (%s)", code_sql)
        message = "Une erreur interne est survenue"
    else:
        message = message_lisible(erreur)

    return JSONResponse(
        status_code=statut,
        content={"code": code, "message": message, "sqlstate": code_sql},
    )


async def gerer_erreur_http(requete: Request, erreur: Exception) -> JSONResponse:
    """Aplatit les erreurs applicatives dans la même forme que les erreurs SQL.

    Sans cela, l'API renverrait deux formats selon l'origine de l'erreur :
    `{"code", "message"}` pour la base, `{"detail": {...}}` pour FastAPI. Un
    client devrait alors gérer les deux, ce qui est exactement ce qu'une API
    normalisée doit lui épargner.
    """
    assert isinstance(erreur, HTTPException)
    detail = erreur.detail

    if isinstance(detail, dict):
        contenu = {
            "code": detail.get("code", "erreur"),
            "message": detail.get("message", ""),
        }
    else:
        contenu = {"code": "erreur", "message": str(detail)}

    return JSONResponse(status_code=erreur.status_code, content=contenu,
                        headers=getattr(erreur, "headers", None))


async def gerer_erreur_validation(requete: Request, erreur: Exception) -> JSONResponse:
    assert isinstance(erreur, RequestValidationError)
    details = "; ".join(
        f"{'.'.join(str(p) for p in e['loc'][1:])} : {e['msg']}" for e in erreur.errors()
    )
    return JSONResponse(
        status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
        content={"code": "requete_invalide", "message": details or "Requête invalide"},
    )
