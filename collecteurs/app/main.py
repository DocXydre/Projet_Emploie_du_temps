"""Point d'entree du service de collecte.

Ce service n'est pas une API produit : il est appele par le coeur metier sur le
reseau Docker interne et ne doit jamais etre publie par le reverse proxy.
"""

from datetime import UTC, datetime

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from app import registre
from app.configuration import configuration
from app.contrat import EtatSante, ResultatCollecte, SanteCollecteur

conf = configuration()

app = FastAPI(
    title="Collecteurs de contraintes",
    version=conf.version,
    description=(
        "Service interne : recuperation et normalisation des contraintes dures "
        "(ICS IDMC, portail McDonald's, SUAPS, boite mail dediee)."
    ),
    docs_url="/documentation",
    openapi_url="/openapi.json",
)


class ReponseSante(BaseModel):
    service: str
    version: str
    etat: EtatSante
    collecteurs: list[SanteCollecteur]
    horodatage: datetime


@app.get("/sante", response_model=ReponseSante, tags=["Systeme"])
async def sante() -> JSONResponse:
    """Sonde d'infrastructure. Contrat fige : Docker, la CI et la supervision en dependent."""
    collecteurs = [await c.sante() for c in registre.tous()]

    if any(c.etat is EtatSante.MORT for c in collecteurs):
        etat = EtatSante.MORT
    elif any(c.etat is EtatSante.DEGRADE for c in collecteurs):
        etat = EtatSante.DEGRADE
    else:
        etat = EtatSante.OK

    reponse = ReponseSante(
        service=conf.service,
        version=conf.version,
        etat=etat,
        collecteurs=collecteurs,
        horodatage=datetime.now(UTC),
    )
    # Le service reste joignable meme degrade : seul un collecteur MORT
    # justifie un 503, qui declenche l'alerte de supervision.
    code = 503 if etat is EtatSante.MORT else 200
    return JSONResponse(status_code=code, content=reponse.model_dump(mode="json"))


@app.get("/collecteurs", response_model=list[str], tags=["Collecte"])
async def lister_collecteurs() -> list[str]:
    return registre.codes()


@app.post("/collecteurs/{code_source}/collecter", response_model=ResultatCollecte, tags=["Collecte"])
async def forcer_collecte(code_source: str) -> ResultatCollecte:
    """Forcage manuel d'une collecte, appelable par le coeur metier ou le bot."""
    collecteur = registre.par_code(code_source)
    if collecteur is None:
        raise HTTPException(status_code=404, detail=f"Collecteur inconnu : {code_source}")
    return await collecteur.executer()
