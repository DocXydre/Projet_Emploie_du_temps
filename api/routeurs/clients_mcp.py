"""Les clients MCP, dans Réglages, Intelligence               (MCP-2, MCP-10)

Créer une clé pour un client, la voir une seule fois avec la commande qui le
branche, la révoquer. Lire les dernières sessions des clients : lequel, quand,
combien d'outils.
"""

import json

import psycopg
from fastapi import APIRouter, HTTPException, Request, status
from pydantic import BaseModel, Field

from api.config import configuration
from api.securite import Authentifie
from api.serveur_mcp import cles

routeur = APIRouter(prefix="/moi", tags=["Clients MCP"])


class NouvelleCle(BaseModel):
    nom: str = Field(min_length=1, max_length=40,
                     description="Le client qui s'en servira : « Claude Code du Mac »")


def adresse_mcp(defaut: str | None) -> str | None:
    """L'adresse de /mcp vue d'un autre appareil, comme celle du calendrier."""
    hote = (configuration().hote_public or defaut or "").strip().rstrip("/")
    if not hote:
        return None
    hote = hote.split("://", 1)[-1]
    port = hote.rpartition(":")[2] if ":" in hote else ""
    # Les ports des tunnels de Tailscale sont chiffrés ; tout autre port est en clair.
    protocole = "http" if port.isdigit() and port not in {"443", "8443", "10000"} else "https"
    return f"{protocole}://{hote}/mcp"


def commandes(adresse: str | None, cle: str) -> dict:
    """F.8.3 : de quoi brancher le client, à copier tel quel."""
    if adresse is None:
        return {}
    # Gemini CLI lit ses serveurs dans ~/.gemini/settings.json : le bloc à y coller,
    # en texte, pour que l'appli n'ait qu'à le copier.
    gemini = {"mcpServers": {"hal": {"httpUrl": adresse, "headers": {"X-Cle-Mcp": cle}}}}
    return {
        "claude_code": f'claude mcp add --transport http hal {adresse} '
                       f'--header "X-Cle-Mcp: {cle}"',
        "gemini_cli": json.dumps(gemini, indent=2),
    }


@routeur.get("/cles-mcp", summary="Les clés de mes clients MCP")
def lister_cles(qui: Authentifie) -> list[dict]:
    return cles.lister_cles(qui.id_utilisateur)


@routeur.post("/cles-mcp", status_code=status.HTTP_201_CREATED,
              summary="Créer la clé d'un client MCP : elle n'est montrée qu'ici")
def creer_cle(nouvelle: NouvelleCle, qui: Authentifie, requete: Request) -> dict:
    try:
        cree = cles.creer(qui.id_utilisateur, nouvelle.nom)
    except psycopg.errors.UniqueViolation:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={"code": "nom_deja_pris",
                    "message": f"Tu as déjà une clé « {nouvelle.nom.strip()} » : révoque-la, "
                               "ou donne un autre nom à celle-ci"}) from None
    adresse = adresse_mcp(requete.url.netloc)
    return {**cree, "adresse": adresse, "commandes": commandes(adresse, cree["cle"])}


@routeur.delete("/cles-mcp/{id_cle}", summary="Révoquer la clé d'un client MCP")
def revoquer_cle(id_cle: int, qui: Authentifie) -> dict:
    if not cles.revoquer(qui.id_utilisateur, id_cle):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"code": "cle_inconnue",
                    "message": "Cette clé n'existe pas, n'est pas la tienne, ou est "
                               "déjà révoquée"})
    return {"revoquee": id_cle}


@routeur.get("/sessions-mcp", summary="Les dernières sessions de mes clients MCP")
def lister_sessions(qui: Authentifie) -> list[dict]:
    return cles.sessions(qui.id_utilisateur)
