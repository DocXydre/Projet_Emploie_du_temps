"""Un appel par l'abonnement : Claude Code sur le serveur     (FOU-10 à FOU-16)

Le module lance Claude Code sans écran, par le SDK Agent, sur l'abonnement du
compte. La consigne est celle de l'API, au caractère près ; le premier message
aussi. Claude Code fait lui-même la boucle, et ses outils sont ceux de HAL,
servis par le serveur MCP de l'API (profil interne), pour ce compte et ce
moment seulement.

Claude Code n'a rien d'autre (FOU-11) : ni shell, ni fichiers, ni web, ni
réglages, ni mémoire de session. Il tourne dans un dossier vide et jetable, et
ne reçoit de l'environnement du serveur que ce qu'il faut pour joindre le
réseau : ni la clé d'API, ni le mot de passe de la base.

Une course se reconnaît à son jeton (FOU-12) : tiré au hasard pour l'appel, il
désigne l'état de la course tenu ici, en mémoire, et disparaît avec elle. Le
serveur MCP le lit pour savoir qui demande, quels outils sont permis, combien
de tours il reste, et si le texte vient d'être requalifié (FOU-13).
"""

import asyncio
import json
import logging
import os
import secrets
import shutil
import tempfile
import threading
import time
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import UTC, datetime

from api.coach import modele, outils
from api.coach.fournisseurs import Arret, Indisponible
from api.config import configuration

LOG = logging.getLogger(__name__)

SERVEUR_MCP = "hal"
EN_TETE_JETON = "X-Jeton-Course"

# FOU-11 : ce que Claude Code garde de l'environnement du serveur. Tout le reste
# lui arrive vide : il n'a pas à voir les secrets de l'API.
GARDES = {"PATH", "LANG", "LC_ALL", "TZ", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY",
          "https_proxy", "http_proxy", "no_proxy", "SSL_CERT_FILE", "SSL_CERT_DIR",
          "NODE_EXTRA_CA_CERTS", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE"}

# Le SDK lit l'environnement de l'API pour lancer Claude Code : cette variable
# coupe sa vérification de version, qui relancerait le binaire pour rien.
os.environ.setdefault("CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK", "1")


# ---------------------------------------------------------------------------
# L'état d'une course, tenu en mémoire le temps de l'appel (FOU-12)
# ---------------------------------------------------------------------------

@dataclass
class EtatCourse:
    id_utilisateur: int
    moment: str
    operation: str
    permis: list                      # les outils du moment (COA-5)
    borne: int                        # COA-7
    deroule: list                     # celui de l'appel : la course y ajoute ses outils
    sur_requalification: Callable[[], None] | None = None
    tours: int = 0
    requalifiee: bool = False
    arret: str | None = None
    verrou: threading.Lock = field(default_factory=threading.Lock)

    @property
    def noms(self) -> set[str]:
        return {o.nom for o in self.permis}


_courses: dict[str, EtatCourse] = {}


def ouvrir(etat: EtatCourse) -> str:
    jeton = secrets.token_urlsafe(32)
    _courses[jeton] = etat
    return jeton


def fermer(jeton: str) -> None:
    _courses.pop(jeton, None)


def etat_de(jeton: str | None) -> EtatCourse | None:
    return _courses.get(jeton or "")


REQUALIFIEE = ("Requalifié en signalement. Arrête-toi là : réponds seulement « suite ». "
               "Tu vas recevoir aussitôt les outils du signalement, et le texte à traiter.")


def executer_outil(etat: EtatCourse, nom: str, arguments: dict) -> tuple[str, bool]:
    """Un outil demandé par Claude Code, exécuté comme ceux de la boucle de l'API.

    Appelé par le serveur MCP, dans l'opération de l'appel. Les tours se
    comptent ici : au-delà de la borne, rien de plus n'est écrit (COA-7).
    """
    with etat.verrou:
        etat.tours += 1
        tour = etat.tours
        depasse = tour > etat.borne
        if depasse and etat.arret is None:
            etat.arret = f"Borne de {etat.borne} tours d'outils dépassée"
    if depasse:
        contenu, refus = json.dumps(
            {"refus": "borne_atteinte",
             "motif": "Tu as utilisé tous tes tours d'outils pour cet appel."},
            ensure_ascii=False), True
    elif nom == "requalifier_en_signalement" and nom in etat.noms and not etat.requalifiee:
        # FOU-13 : la course s'arrête ; le module la relance avec le signalement.
        etat.requalifiee = True
        if etat.sur_requalification is not None:
            etat.sur_requalification()
        contenu, refus = REQUALIFIEE, False
    else:
        contenu, refus = outils.executer_outil(nom, etat.id_utilisateur, arguments or {},
                                               etat.noms)
    etat.deroule.append({"tour": tour, "outil": nom, "arguments": arguments,
                         "refus": bool(refus), "resultat": contenu[:400]})
    return contenu, refus


# ---------------------------------------------------------------------------
# Lancer Claude Code
# ---------------------------------------------------------------------------

_places: threading.BoundedSemaphore | None = None


def _place() -> threading.BoundedSemaphore:
    global _places
    if _places is None:
        _places = threading.BoundedSemaphore(max(configuration().claude_code_courses_max, 1))
    return _places


# Remplaçable dans les essais : un faux client qui joue Claude Code.
def _client(options):
    from claude_agent_sdk import ClaudeSDKClient
    return ClaudeSDKClient(options=options)


def environnement(jeton_abonnement: str, dossier: str) -> dict[str, str]:
    """FOU-11 : l'environnement de Claude Code. Ce qui n'est pas gardé arrive vide."""
    env = {cle: "" for cle in os.environ if cle not in GARDES}
    env.update({
        "HOME": dossier,
        "CLAUDE_CONFIG_DIR": os.path.join(dossier, ".claude"),
        "CLAUDE_CODE_OAUTH_TOKEN": jeton_abonnement,
        # Une clé d'API passerait devant l'abonnement : elle est toujours vide.
        "ANTHROPIC_API_KEY": "",
        "ANTHROPIC_AUTH_TOKEN": "",
        "DISABLE_AUTOUPDATER": "1",
        "DISABLE_TELEMETRY": "1",
        "DISABLE_ERROR_REPORTING": "1",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    })
    return env


def _options(systeme: str, modele_nom: str, dossier: str, jeton_abonnement: str,
             outils_permis: list[str], jeton_course: str | None, tours_max: int):
    from claude_agent_sdk import ClaudeAgentOptions

    serveurs = {}
    if jeton_course is not None:
        serveurs[SERVEUR_MCP] = {"type": "http", "url": configuration().mcp_adresse_interne,
                                 "headers": {EN_TETE_JETON: jeton_course}}
    return ClaudeAgentOptions(
        tools=[],                                # FOU-11 : aucun outil intégré
        allowed_tools=[f"mcp__{SERVEUR_MCP}__{nom}" for nom in outils_permis],
        mcp_servers=serveurs,
        strict_mcp_config=True,
        system_prompt=systeme,                   # FOU-10 : remplace, n'ajoute pas
        setting_sources=[],                      # ni réglages, ni CLAUDE.md
        model=modele_nom,
        max_turns=tours_max,
        cwd=dossier,
        env=environnement(jeton_abonnement, dossier),
    )


def _executer(coro):
    """Le module HAL est synchrone : la course a sa propre boucle d'événements.

    Un appelant déjà dans une boucle (le bot) la lance dans un fil à part.
    """
    try:
        asyncio.get_running_loop()
    except RuntimeError:
        return asyncio.run(coro)
    with ThreadPoolExecutor(max_workers=1) as fil:
        return fil.submit(asyncio.run, coro).result()


def _reprise(info) -> datetime | None:
    instant = getattr(info, "resets_at", None)
    if not instant:
        return None
    if instant > 10_000_000_000:          # en millisecondes
        instant = instant / 1000
    return datetime.fromtimestamp(instant, UTC)


@dataclass
class Passage:
    texte: str = ""
    entree: int = 0
    cache: int = 0
    cache_ecrit: int = 0
    sortie: int = 0
    tours_modele: int = 0
    # Gemini CLI : ses identifiants Google, s'il les a renouvelés pendant la course.
    secret_neuf: str | None = None


def _compter(passage: Passage, usage: dict | None) -> None:
    usage = usage or {}
    lus = int(usage.get("cache_read_input_tokens") or 0)
    ecrits = int(usage.get("cache_creation_input_tokens") or 0)
    # COA-21 : l'entrée compte tout ce que le modèle a lu, cache compris.
    passage.entree += int(usage.get("input_tokens") or 0) + lus + ecrits
    passage.cache += lus
    passage.cache_ecrit += ecrits
    passage.sortie += int(usage.get("output_tokens") or 0)


async def _recevoir(client, passage: Passage) -> None:
    """Lit la réponse d'un message jusqu'au résultat. Lève Indisponible si
    l'abonnement cède (FOU-4, FOU-5, FOU-6)."""
    from claude_agent_sdk import AssistantMessage, RateLimitEvent, ResultMessage, TextBlock

    texte = []
    async for message in client.receive_response():
        if isinstance(message, RateLimitEvent):
            info = message.rate_limit_info
            if info.status == "rejected":
                raise Indisponible("limite", "Limite d'usage de l'abonnement atteinte "
                                   f"({info.rate_limit_type or 'quota'})", _reprise(info))
        elif isinstance(message, AssistantMessage):
            if message.error == "authentication_failed":
                raise Indisponible("jeton", "Jeton d'abonnement refusé")
            if message.error in ("rate_limit", "billing_error"):
                raise Indisponible("limite", "Limite d'usage de l'abonnement atteinte")
            if message.error in ("server_error", "unknown"):
                raise Indisponible("injoignable", f"Claude Code : erreur {message.error}")
            morceaux = [b.text for b in message.content if isinstance(b, TextBlock)]
            if morceaux:
                texte = morceaux          # le dernier message porte la réponse
        elif isinstance(message, ResultMessage):
            _compter(passage, message.usage)
            passage.tours_modele += message.num_turns or 0
            if message.is_error:
                statut = message.api_error_status
                detail = "; ".join(message.errors or []) or message.subtype
                if statut == 429:
                    raise Indisponible("limite", f"Limite d'usage : {detail}")
                if statut in (401, 403):
                    raise Indisponible("jeton", f"Jeton refusé : {detail}")
                if message.subtype == "error_max_turns":
                    raise Arret("Borne de tours de Claude Code dépassée")
                raise Indisponible("injoignable", f"Claude Code : {detail}"[:300])
            passage.texte = (message.result or "\n".join(texte)).strip()
            return
    passage.texte = "\n".join(texte).strip()


async def _dialogue(options, messages: list[str], relecture: Callable[[str], str | None],
                    passage: Passage) -> None:
    """Un ou deux messages dans la même session : la réponse, puis la relecture
    éventuelle contre ce qui est en base (COA-30)."""
    from claude_agent_sdk import ClaudeSDKError, CLIConnectionError

    try:
        async with _client(options) as client:
            for message in messages:
                await client.query(message)
                await _recevoir(client, passage)
            suite = relecture(passage.texte)
            if suite is not None:
                premier = passage.texte
                await client.query(suite)
                await _recevoir(client, passage)
                if passage.texte.strip().strip(".").upper() == "OK":
                    passage.texte = premier
    except (CLIConnectionError, ClaudeSDKError) as erreur:
        raise Indisponible("injoignable", f"Claude Code : {erreur}"[:300]) from erreur


def courir(etat: EtatCourse, systeme: str, premier: str, modele_nom: str,
           jeton_abonnement: str, limite: float,
           relecture: Callable[[str], str | None] = lambda texte: None) -> Passage:
    """Une course entière : Claude Code répond au premier message avec les outils
    du moment, et rend son texte et ce qu'il a consommé.

    `limite` est l'instant (monotonic) où l'appel doit avoir fini (COA-16).
    """
    restant = limite - time.monotonic()
    if restant <= 1 or not _place().acquire(timeout=max(restant - 1, 0)):
        raise Indisponible("injoignable", "Trop de Claude Code en cours sur le serveur")
    dossier = tempfile.mkdtemp(prefix="hal-course-")
    jeton = ouvrir(etat)
    passage = Passage()
    try:
        options = _options(systeme, modele_nom, dossier, jeton_abonnement,
                           [o.nom for o in etat.permis if not o.cache], jeton,
                           etat.borne + 6)
        restant = limite - time.monotonic()
        try:
            _executer(asyncio.wait_for(_dialogue(options, [premier], relecture, passage),
                                       timeout=max(restant, 1)))
        except TimeoutError:
            raise Arret("Délai dépassé") from None
        if etat.arret and not etat.requalifiee:
            raise Arret(etat.arret)
        return passage
    finally:
        fermer(jeton)
        shutil.rmtree(dossier, ignore_errors=True)
        _place().release()


def ecrire(jeton_abonnement: str, systeme: str, texte: str, modele_nom: str,
           delai: float) -> modele.Tour:
    """FOU-15 : un appel sans outils (aiguillage, résumé de la mémoire), par
    l'abonnement. Même forme que `modele.ecrire`."""
    limite = time.monotonic() + delai
    if not _place().acquire(timeout=max(delai - 1, 0)):
        raise Indisponible("injoignable", "Trop de Claude Code en cours sur le serveur")
    dossier = tempfile.mkdtemp(prefix="hal-ecrit-")
    passage = Passage()
    try:
        options = _options(systeme, modele_nom, dossier, jeton_abonnement, [], None, 1)
        try:
            _executer(asyncio.wait_for(
                _dialogue(options, [texte], lambda t: None, passage),
                timeout=max(limite - time.monotonic(), 1)))
        except TimeoutError:
            raise Indisponible("injoignable", "Claude Code n'a pas répondu à temps") from None
    finally:
        shutil.rmtree(dossier, ignore_errors=True)
        _place().release()
    return modele.Tour(texte=passage.texte, tokens_entree=passage.entree,
                       tokens_cache=passage.cache, tokens_cache_ecrit=passage.cache_ecrit,
                       tokens_sortie=passage.sortie, arret="end_turn")


def essayer(jeton_abonnement: str) -> None:
    """FOU-18 : un appel minimal avant de garder un jeton. Lève Indisponible si
    l'abonnement ne répond pas."""
    tour = ecrire(jeton_abonnement, "Réponds seulement OK.", "OK ?",
                  configuration().coach_modele_aiguillage or configuration().coach_modele,
                  60.0)
    if not tour.texte:
        raise Indisponible("injoignable", "Claude Code n'a rien répondu")
