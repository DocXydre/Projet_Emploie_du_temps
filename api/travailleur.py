"""Le travailleur : l'ordonnanceur, le bot et les appels planifiés de HAL

    uvicorn api.travailleur:app --host 0.0.0.0 --port 8000

La même image que l'API, dans un conteneur à part. L'API sert l'appli ; le
travailleur fait ce que personne n'attend : collectes, placement du matin,
notifications, récap du soir et révision du dimanche de HAL, bot
d'administration. Un déploiement, un plantage ou un appel de HAL de sept
minutes ne touchent ainsi qu'un des deux.

Il garde un serveur web, pour deux choses seulement :

  /mcp     Claude Code et Gemini CLI, lancés ici pour un appel planifié, y
           demandent leurs outils. L'état de leur course est tenu en mémoire,
           dans ce processus (FOU-12), et leur jeton ne vaut que depuis le
           conteneur lui-même (MCP-14) : ils joignent donc le travailleur, à
           la même adresse qu'avant, http://127.0.0.1:8000/mcp.
  /sante   la sonde de son conteneur, que l'API relaie dans la sienne.

Rien n'est publié hors du réseau de Docker.
"""

from contextlib import asynccontextmanager

import psycopg
from fastapi import FastAPI

from api import administration, bot, ordonnanceur
from api.base import arreter_pool, demarrer_pool, un_seul
from api.config import configuration
from api.serveur_mcp import serveur as serveur_mcp

conf = configuration()


@asynccontextmanager
async def cycle_de_vie(app: FastAPI):
    # ADM-3 : ses erreurs se lisent dans /erreurs, à côté de celles de l'API.
    administration.installer("travailleur")
    demarrer_pool()
    # ORDONNANCEUR_ACTIF=false le laisse tourner sans rien déclencher : la
    # maquette et les essais le veulent ainsi.
    if conf.ordonnanceur_actif:
        ordonnanceur.demarrer()
        await bot.demarrer_bot()
    async with serveur_mcp.en_service():
        yield
    await bot.arreter_bot()
    ordonnanceur.arreter()
    arreter_pool()


app = FastAPI(title="Planification personnelle : travailleur", version=conf.version,
              docs_url=None, redoc_url=None, openapi_url=None, lifespan=cycle_de_vie)

app.router.add_route("/mcp", serveur_mcp.Porte(), include_in_schema=False)


@app.get("/sante")
def sante() -> dict:
    try:
        un_seul("SELECT 1 AS ok")
        base = "ok"
    except psycopg.Error:
        base = "injoignable"
    taches = ordonnanceur.taches_programmees()
    en_marche = base == "ok" and (bool(taches) or not conf.ordonnanceur_actif)
    return {
        "service": "planif-travailleur",
        "version": conf.version,
        "etat": "ok" if en_marche else "degrade",
        "base": base,
        "ordonnanceur": taches,
        "bot": bot.identite() or "non démarré",
    }
