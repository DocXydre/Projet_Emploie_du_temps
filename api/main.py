"""Point d'entrée de l'API.

L'API est volontairement mince : elle lit des vues et appelle des fonctions.
Toute la logique — disponibilités, placement, récurrence, enchaînements,
stock — vit dans PostgreSQL.
"""

from contextlib import asynccontextmanager

import psycopg
from fastapi import Depends, FastAPI
from fastapi.exceptions import RequestValidationError
from fastapi.responses import Response
from starlette.exceptions import HTTPException as StarletteHTTPException

from api import bot, ordonnanceur
from api.amorcage import amorcer_assignations, amorcer_sources
from api.base import arreter_pool, demarrer_pool, un_seul
from api.calendrier import flux_ics
from api.config import configuration
from api.erreurs import gerer_erreur_http, gerer_erreur_sql, gerer_erreur_validation
from api.routeurs import (
    absences,
    contraintes,
    notifications,
    occurrences,
    planning,
    stock,
    taches,
)
from api.securite import Appelant, Authentifie, appelant_par_url

conf = configuration()


@asynccontextmanager
async def cycle_de_vie(app: FastAPI):
    demarrer_pool()
    amorcer_sources()
    amorcer_assignations()
    if conf.ordonnanceur_actif:
        ordonnanceur.demarrer()
        await bot.demarrer_bot()
    yield
    await bot.arreter_bot()
    ordonnanceur.arreter()
    arreter_pool()


app = FastAPI(
    title="Planification personnelle",
    version=conf.version,
    description=(
        "Croise des emplois du temps hétérogènes, en déduit les moments libres "
        "et y place les tâches récurrentes.\n\n"
        "Les règles métier vivent dans PostgreSQL : cette API les expose, elle "
        "ne les duplique pas."
    ),
    docs_url="/documentation",
    openapi_url="/openapi.json",
    lifespan=cycle_de_vie,
)

# Une seule forme d'erreur pour tout le monde : {code, message}.
app.add_exception_handler(psycopg.Error, gerer_erreur_sql)
app.add_exception_handler(StarletteHTTPException, gerer_erreur_http)
app.add_exception_handler(RequestValidationError, gerer_erreur_validation)

app.include_router(planning.routeur)
app.include_router(taches.routeur)
app.include_router(occurrences.routeur)
app.include_router(contraintes.routeur)
app.include_router(stock.routeur)
app.include_router(notifications.routeur)
app.include_router(absences.routeur)


@app.get("/sante", tags=["Système"], summary="Sonde d'infrastructure")
def sante() -> dict:
    try:
        un_seul("SELECT 1 AS ok")
        base = "ok"
    except psycopg.Error:
        base = "injoignable"

    return {
        "service": "planif-api",
        "version": conf.version,
        "etat": "ok" if base == "ok" else "degrade",
        "base": base,
        "ordonnanceur": ordonnanceur.taches_programmees(),
        "bot": bot.identite() or "non démarré",
    }


@app.get("/moi", tags=["Système"], summary="Profil de l'appelant")
def moi(qui: Authentifie) -> Appelant:
    return qui


@app.get(
    "/planning.ics",
    tags=["Planning"],
    summary="Flux iCalendar",
    response_class=Response,
    responses={200: {"content": {"text/calendar": {}}}},
)
def calendrier(qui: Appelant = Depends(appelant_par_url), jours: int | None = None) -> Response:
    """Flux à abonner dans une application de calendrier.

    La clé passe dans l'URL et non dans un en-tête : les applications de
    calendrier ne savent pas en envoyer un.
    """
    return Response(
        content=flux_ics(qui.id_utilisateur, jours),
        media_type="text/calendar; charset=utf-8",
        headers={"Content-Disposition": 'inline; filename="planning.ics"'},
    )
