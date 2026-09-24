"""Point d'entrée de l'API.

L'API est volontairement mince : elle lit des vues et appelle des fonctions.
Toute la logique — disponibilités, placement, récurrence, enchaînements —
vit dans PostgreSQL.
"""

from contextlib import asynccontextmanager

import psycopg
from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import Response
from starlette.exceptions import HTTPException as StarletteHTTPException

from api import bot, conversation, ordonnanceur
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
    taches,
    trajets,
)
from api.securite import CONTENUS, Abonne, Appelant, Authentifie

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
app.include_router(notifications.routeur)
app.include_router(absences.routeur)
app.include_router(trajets.routeur)


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


@app.get("/moi/calendrier", tags=["Planning"], summary="URL d'abonnement au calendrier")
def abonnement(qui: Authentifie, requete: Request) -> dict:
    """Adresse à donner à l'application Calendrier du téléphone.

    L'hôte vient de `HOTE_PUBLIC` s'il est renseigné, sinon de la requête
    elle-même. La différence compte : une réponse construite depuis la requête
    dit « localhost » quand on l'interroge depuis le Mac, ce qui ne veut rien
    dire pour le téléphone. HOTE_PUBLIC sert à donner une bonne fois le nom par
    lequel les autres appareils joignent la machine.
    """
    lien = conversation.url_calendrier(qui.id_utilisateur, requete.url.netloc)
    assert lien is not None
    return {
        **lien,
        "deduit_de_la_requete": not conf.hote_public,
        "note": (
            "Cette URL ne donne que la lecture du planning. Elle se renouvelle "
            "par POST /moi/calendrier/renouveler, ce qui coupe les abonnements "
            "en place."
        ),
    }


@app.post(
    "/moi/calendrier/renouveler",
    tags=["Planning"],
    summary="Renouveler le jeton d'abonnement",
)
def renouveler_abonnement(qui: Authentifie, requete: Request) -> dict:
    """Révoque l'abonnement en place. Il faudra se réabonner avec la nouvelle URL."""
    conversation.renouveler_calendrier(qui.id_utilisateur)
    lien = conversation.url_calendrier(qui.id_utilisateur, requete.url.netloc)
    assert lien is not None
    return lien


@app.get("/moi/calendriers", tags=["Planning"], summary="Mes calendriers composés")
def mes_calendriers(qui: Authentifie, requete: Request) -> list[dict]:
    """Un calendrier composé par ligne, avec son adresse d'abonnement."""
    return [
        {**ligne,
         "url": (conversation.url_abonnement(ligne["jeton"], requete.url.netloc) or {})
                .get("url")}
        for ligne in conversation.calendriers_de(qui.id_utilisateur)
    ]


@app.post("/moi/calendriers", tags=["Planning"], summary="Composer un calendrier",
          status_code=201)
def composer_calendrier(qui: Authentifie, requete: Request,
                        libelle: str, personnes: str, contenus: str) -> dict:
    """Personnes par pseudo, contenus par famille, les deux séparés par des virgules.

    Exemple : `libelle=Cours de Lorette&personnes=lorette&contenus=cours`. Les
    familles reconnues sont celles de NOT-6.
    """
    from api.securite import _comptes, _liste

    familles = _liste(contenus)
    comptes = _comptes(_liste(personnes), qui.id_utilisateur)
    if not familles or not comptes:
        raise HTTPException(
            status_code=400,
            detail={"code": "calendrier_vide",
                    "message": "Un calendrier demande au moins une personne "
                               "et un contenu"},
        )

    inconnus = [c for c in familles if c not in CONTENUS]
    if inconnus:
        raise HTTPException(
            status_code=400,
            detail={"code": "contenu_inconnu",
                    "message": f"Contenu inconnu : {', '.join(inconnus)}. "
                               f"Au choix : {', '.join(CONTENUS)}"},
        )

    cree = conversation.creer_calendrier(qui.id_utilisateur, libelle, comptes, familles)
    assert cree is not None
    lien = conversation.url_abonnement(cree["jeton"], requete.url.netloc) or {}
    return {**cree, "url": lien.get("url")}


@app.delete("/moi/calendriers/{id_calendrier}", tags=["Planning"],
            summary="Supprimer un calendrier composé")
def retirer_calendrier(qui: Authentifie, id_calendrier: int) -> dict:
    """Son adresse cesse aussitôt de répondre. Les autres continuent (NOT-7)."""
    if not conversation.supprimer_calendrier(qui.id_utilisateur, id_calendrier):
        raise HTTPException(
            status_code=404,
            detail={"code": "calendrier_inconnu",
                    "message": "Ce calendrier n'existe pas, ou n'est pas le tien"},
        )
    return {"supprime": id_calendrier}


@app.get(
    "/planning.ics",
    tags=["Planning"],
    summary="Flux iCalendar",
    response_class=Response,
    responses={200: {"content": {"text/calendar": {}}}},
)
def calendrier(abonnement: Abonne, jours: int | None = None) -> Response:
    """Flux à abonner dans une application de calendrier.

    La clé passe dans l'URL et non dans un en-tête : les applications de
    calendrier ne savent pas en envoyer un.

    Le jeton d'un compte donne tout son planning, et se restreint au besoin
    avec `qui` et `quoi` : « ?qui=lorette&quoi=cours,sport ». Le jeton d'un
    calendrier composé donne ce qu'il déclare, sans discussion (NOT-6, NOT-8).
    """
    return Response(
        content=flux_ics(abonnement, jours),
        media_type="text/calendar; charset=utf-8",
        headers={"Content-Disposition": 'inline; filename="planning.ics"'},
    )
