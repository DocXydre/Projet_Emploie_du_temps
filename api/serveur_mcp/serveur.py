"""Le serveur MCP de HAL, sur /mcp                         (MCP-1 à MCP-13)

Un serveur MCP dans le processus de l'API, en HTTP sans état : chaque requête
arrive seule, avec sa clé, et la réponse part en JSON. Rien n'est tenu en
mémoire d'une requête à l'autre, sinon le compte des appels de chaque clé
(MCP-13) : un redémarrage de l'API ne coupe aucun client.

La porte vérifie la clé avant que le SDK ne lise quoi que ce soit, et pose le
titulaire dans la requête. Les outils, les ressources et l'invite le relisent
là : aucun ne prend un identifiant d'utilisateur (MCP-3).

Les outils sont ceux du catalogue externe, exécutés comme ceux du coach (COA-23
et suivantes) : une transaction par outil, un refus de la base rendu au modèle
avec son motif (MCP-9). Chaque appel s'écrit sous l'opération de sa session,
avec l'acteur « agent » (MCP-10).
"""

import json
import logging
import time
from collections import defaultdict, deque
from contextlib import asynccontextmanager
from functools import lru_cache, partial

import anyio
import mcp_types as types
from mcp.server import Server
from mcp.server.streamable_http_manager import StreamableHTTPSessionManager
from mcp.shared.exceptions import MCPError
from mcp_types.jsonrpc import INVALID_PARAMS
from starlette.datastructures import Headers
from starlette.responses import JSONResponse

from api import operation
from api.coach import dossier
from api.coach.outils import executer_outil
from api.config import configuration
from api.serveur_mcp import catalogue, cles
from api.serveur_mcp.cles import Porteur

LOG = logging.getLogger(__name__)

EN_TETE = "x-cle-mcp"

# MCP-13 : soixante appels d'outil par minute et par clé.
APPELS_PAR_MINUTE = 60

_appels: dict[int, deque] = defaultdict(deque)


def debit_permis(id_cle: int, maintenant: float | None = None) -> bool:
    """MCP-13 : une fenêtre glissante d'une minute, par clé."""
    maintenant = time.monotonic() if maintenant is None else maintenant
    file = _appels[id_cle]
    while file and file[0] <= maintenant - 60:
        file.popleft()
    if len(file) >= APPELS_PAR_MINUTE:
        return False
    file.append(maintenant)
    return True


def _porteur(ctx) -> Porteur:
    """Le titulaire de la clé, posé par la porte dans la requête HTTP."""
    requete = getattr(ctx, "request", None)
    qui = (getattr(requete, "scope", None) or {}).get("state", {}).get("hal")
    if qui is None:
        # La porte refuse avant : n'arrive que si le serveur est servi autrement.
        raise MCPError(INVALID_PARAMS, "Clé MCP absente")
    return qui


def _client(ctx) -> str:
    """Le nom du client, à défaut de mieux celui de son navigateur HTTP."""
    requete = getattr(ctx, "request", None)
    agent = requete.headers.get("user-agent", "") if requete is not None else ""
    return (agent.split(" ")[0] or "client MCP")[:60]


def _texte(texte: str) -> list[types.TextContent]:
    return [types.TextContent(type="text", text=texte)]


# ---------------------------------------------------------------------------
# Outils
# ---------------------------------------------------------------------------

def _declaration(outil) -> types.Tool:
    ecrit = outil.nom in catalogue.ECRITURE
    return types.Tool(
        name=outil.nom, description=outil.description, input_schema=outil.schema,
        # MCP-8 : le client s'en sert pour demander confirmation ; le serveur ne
        # s'y fie pas.
        annotations=types.ToolAnnotations(read_only_hint=not ecrit, destructive_hint=False,
                                          idempotent_hint=not ecrit, open_world_hint=False))


async def lister_outils(ctx, params) -> types.ListToolsResult:
    _porteur(ctx)
    return types.ListToolsResult(
        tools=[_declaration(o) for o in catalogue.EXTERNE.values()])


def executer(qui: Porteur, client: str, nom: str, arguments: dict) -> tuple[str, bool]:
    """Un outil, pour le titulaire de la clé, dans l'opération de sa session."""
    session = cles.session_de(qui.id_cle, client)
    jeton = catalogue.client_courant.set(session["client"])
    try:
        with operation.ouvrir_a_part(f"mcp : {session['client']}", "agent",
                                     session["operation"]):
            try:
                texte, refus = executer_outil(nom, qui.id_utilisateur, arguments,
                                              set(catalogue.EXTERNE), catalogue.EXTERNE)
            except Exception:
                LOG.exception("Outil MCP %s en échec", nom)
                texte, refus = json.dumps(
                    {"refus": "erreur_interne",
                     "motif": "L'outil a échoué côté serveur. Réessaie plus tard."},
                    ensure_ascii=False), True
            cles.noter_appel(session["id_session"], nom, texte, refus)
    finally:
        catalogue.client_courant.reset(jeton)
    return texte, refus


async def appeler_outil(ctx, params: types.CallToolRequestParams) -> types.CallToolResult:
    qui = _porteur(ctx)
    if not debit_permis(qui.id_cle):
        return types.CallToolResult(content=_texte(json.dumps(
            {"refus": "trop_d_appels",
             "motif": f"Au plus {APPELS_PAR_MINUTE} appels d'outil par minute. "
                      "Attends un peu avant de reprendre."}, ensure_ascii=False)),
            is_error=True)
    texte, refus = await anyio.to_thread.run_sync(
        partial(executer, qui, _client(ctx), params.name, params.arguments or {}))
    return types.CallToolResult(content=_texte(texte), is_error=refus)


# ---------------------------------------------------------------------------
# Ressources : le dossier, un chapitre par ressource (MCP-7)
# ---------------------------------------------------------------------------

SOMMAIRE = "hal://dossier/sommaire"


def _uri(numero: str) -> str:
    return f"hal://dossier/{numero}"


async def lister_ressources(ctx, params) -> types.ListResourcesResult:
    _porteur(ctx)
    ressources = [types.Resource(uri=SOMMAIRE, name="Sommaire du dossier de HAL",
                                 mime_type="text/markdown")]
    ressources += [types.Resource(uri=_uri(numero), name=titre, mime_type="text/markdown")
                   for numero, titre in catalogue.chapitres_du_dossier()]
    return types.ListResourcesResult(resources=ressources)


async def lire_ressource(ctx, params: types.ReadResourceRequestParams
                         ) -> types.ReadResourceResult:
    _porteur(ctx)
    uri = str(params.uri)
    if uri == SOMMAIRE:
        texte = dossier.sommaire()
    else:
        texte = dossier.chapitre(uri.removeprefix("hal://dossier/"))
    if not texte:
        raise MCPError(INVALID_PARAMS, f"Ressource inconnue : {uri}")
    return types.ReadResourceResult(contents=[
        types.TextResourceContents(uri=uri, mime_type="text/markdown", text=texte)])


# ---------------------------------------------------------------------------
# L'invite `hal` (MCP-6)
# ---------------------------------------------------------------------------

INVITE = "hal"


async def lister_invites(ctx, params) -> types.ListPromptsResult:
    _porteur(ctx)
    return types.ListPromptsResult(prompts=[types.Prompt(
        name=INVITE, title="Parler à HAL",
        description="Charge HAL : son cadre, le socle de son dossier, ce qu'il sait de toi "
                    "et sa mémoire.")])


async def lire_invite(ctx, params: types.GetPromptRequestParams) -> types.GetPromptResult:
    qui = _porteur(ctx)
    if params.name != INVITE:
        raise MCPError(INVALID_PARAMS, f"Invite inconnue : {params.name}")
    texte = await anyio.to_thread.run_sync(catalogue.invite, qui.id_utilisateur)
    return types.GetPromptResult(
        description="HAL, son dossier, ton contexte et sa mémoire",
        messages=[types.PromptMessage(role="user",
                                      content=types.TextContent(type="text", text=texte))])


# ---------------------------------------------------------------------------
# Le serveur, sa porte et son cycle de vie
# ---------------------------------------------------------------------------

class PresentationDuClient:
    """MCP-10 : un client qui se présente ouvre une session à son nom.

    Le nom vient de `clientInfo`, dans la poignée de main. Un client qui n'en
    fait pas (le protocole de juillet 2026 s'en passe) prend son en-tête
    User-Agent, au premier outil.
    """

    async def __call__(self, ctx, call_next):
        if ctx.method == "initialize":
            info = (ctx.params or {}).get("clientInfo") or {}
            nom = " ".join(str(x) for x in (info.get("name"), info.get("version")) if x)
            try:
                qui = _porteur(ctx)
                await anyio.to_thread.run_sync(cles.ouvrir_session, qui.id_cle,
                                               nom or _client(ctx))
            except Exception:
                LOG.exception("Session MCP non ouverte")
        return await call_next(ctx)


@lru_cache
def serveur() -> Server:
    s = Server(
        "hal", version=configuration().version, title="HAL",
        description="Le planning du foyer, la maison et le coach sportif HAL",
        instructions=catalogue.consigne(),
        on_list_tools=lister_outils, on_call_tool=appeler_outil,
        on_list_resources=lister_ressources, on_read_resource=lire_ressource,
        on_list_prompts=lister_invites, on_get_prompt=lire_invite)
    s.middleware.append(PresentationDuClient())
    return s


_gestionnaire: StreamableHTTPSessionManager | None = None


@asynccontextmanager
async def en_service():
    """Le gestionnaire HTTP du SDK vit le temps de l'API. Il ne sert qu'une fois :
    chaque démarrage en crée un neuf."""
    global _gestionnaire
    _gestionnaire = StreamableHTTPSessionManager(app=serveur(), stateless=True,
                                                 json_response=True)
    try:
        async with _gestionnaire.run():
            yield
    finally:
        _gestionnaire = None


def _cle(headers: Headers) -> str | None:
    """MCP-2 : la clé dans `X-Cle-Mcp`, ou en jeton porteur pour un client qui ne
    sait envoyer que celui-là."""
    cle = headers.get(EN_TETE)
    if cle:
        return cle.strip()
    autorisation = headers.get("authorization", "")
    if autorisation.lower().startswith("bearer "):
        return autorisation[7:].strip()
    return None


class Porte:
    """La porte de /mcp : une clé MCP vivante, ou rien ne passe.

    Une application ASGI plutôt qu'une route FastAPI : le SDK lit lui-même la
    requête et écrit sa réponse.
    """

    async def __call__(self, scope, receive, send) -> None:
        if scope["type"] == "http":
            await _passer(scope, receive, send)


async def _passer(scope, receive, send) -> None:
    qui = await anyio.to_thread.run_sync(cles.porteur, _cle(Headers(scope=scope)))
    if qui is None:
        reponse = JSONResponse(
            {"code": "cle_mcp_invalide",
             "message": "Clé MCP absente, inconnue ou révoquée. Une clé se crée dans "
                        "l'appli HAL, Réglages, Intelligence."},
            status_code=401)
        await reponse(scope, receive, send)
        return
    if _gestionnaire is None:
        await JSONResponse({"code": "indisponible", "message": "Le serveur MCP démarre"},
                           status_code=503)(scope, receive, send)
        return
    scope.setdefault("state", {})["hal"] = qui
    await _gestionnaire.handle_request(scope, receive, send)
