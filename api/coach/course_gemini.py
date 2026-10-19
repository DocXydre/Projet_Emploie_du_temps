"""Un appel par Gemini CLI sur le serveur                    (FOU-11, FOU-17)

La même course que celle de Claude Code (module `course`), avec Gemini CLI :
la consigne de l'API remplace la sienne (GEMINI_SYSTEM_MD), le premier message
est le même, et ses seuls outils sont ceux de HAL, servis par le serveur MCP
de l'API sous le jeton de la course. L'état de la course, la borne des tours
et la requalification sont ceux du module `course`.

Le secret du compte est l'un des deux :
- le contenu de ~/.gemini/oauth_creds.json, après « gemini » et « Se connecter
  avec Google » sur sa machine : c'est son compte Google, et son abonnement ;
- une clé de l'API Gemini (AIza…).

Gemini CLI tourne dans un dossier vide et jetable, qui lui sert de maison :
ni réglages, ni GEMINI.md, ni extensions. Ses outils intégrés (fichiers,
recherche, web) ne sont pas chargés : `tools.core` ne nomme que ceux de HAL.
"""

import json
import logging
import os
import re
import shutil
import subprocess
import tempfile
import time
from collections.abc import Callable
from datetime import UTC, datetime, timedelta

from api.coach import course, modele
from api.coach.course import EN_TETE_JETON, GARDES, SERVEUR_MCP, EtatCourse, Passage
from api.coach.fournisseurs import Arret, Indisponible
from api.config import configuration

LOG = logging.getLogger(__name__)

# Gemini CLI quitte avec ce code quand l'identification échoue.
SORTIE_IDENTIFICATION = 41


def nom_mcp(outil: str) -> str:
    """Le nom que Gemini CLI donne à un outil MCP de HAL."""
    return f"mcp_{SERVEUR_MCP}_{outil}"


def compte_google(secret: str) -> dict | None:
    """Les identifiants d'un compte Google collés tels quels, ou None pour une clé."""
    texte = secret.strip()
    if not texte.startswith("{"):
        return None
    try:
        lus = json.loads(texte)
    except ValueError:
        return None
    return lus if isinstance(lus, dict) else None


def secret_valide(secret: str) -> str | None:
    """Le motif d'un secret qui ne peut pas servir, avant même de l'essayer."""
    lus = compte_google(secret)
    if lus is not None:
        return None if lus.get("refresh_token") else (
            "Ce fichier n'a pas de refresh_token : reconnecte Gemini CLI sur ta machine, "
            "puis recolle ~/.gemini/oauth_creds.json")
    if secret.strip().startswith("{"):
        return "Ce n'est pas du JSON lisible : colle le fichier oauth_creds.json en entier"
    if not re.fullmatch(r"AIza[0-9A-Za-z_\-]{30,}", secret.strip()):
        return ("Colle le contenu de ~/.gemini/oauth_creds.json, ou une clé de l'API "
                "Gemini (AIza…)")
    return None


def reglages(outils_permis: list[str], jeton_course: str | None, tours_max: int) -> dict:
    """Le settings.json de la course : HAL pour seul serveur, ses outils pour seuls outils."""
    google = {"selectedType": "oauth-personal"}
    rendu = {
        "security": {"auth": google, "folderTrust": {"enabled": False}},
        "privacy": {"usageStatisticsEnabled": False},
        "telemetry": {"enabled": False},
        # FOU-11 : une liste vide ne charge aucun outil intégré.
        "tools": {"core": [nom_mcp(nom) for nom in outils_permis]},
        "model": {"maxSessionTurns": tours_max},
        # FOU-4 : un quota épuisé passe la main tout de suite. Gemini CLI
        # réessaierait sinon plus de trois minutes, au-delà du délai de l'appel.
        "general": {"maxAttempts": 1},
    }
    if jeton_course is not None:
        rendu["mcpServers"] = {SERVEUR_MCP: {
            "httpUrl": configuration().mcp_adresse_interne,
            "headers": {EN_TETE_JETON: jeton_course},
            # La course est déjà bornée par HAL : pas de confirmation à demander.
            "trust": True,
            "includeTools": list(outils_permis),
        }}
    return rendu


def preparer(dossier: str, secret: str, systeme: str, outils_permis: list[str],
             jeton_course: str | None, tours_max: int = 1) -> dict[str, str]:
    """Écrit la maison de Gemini CLI et rend son environnement (FOU-11)."""
    maison = os.path.join(dossier, ".gemini")
    os.makedirs(maison, exist_ok=True)
    os.makedirs(os.path.join(dossier, "vide"), exist_ok=True)
    regle = reglages(outils_permis, jeton_course, tours_max)
    # L'environnement de Gemini CLI est celui-ci, en entier : rien d'autre du
    # serveur ne lui arrive.
    env = {cle: valeur for cle, valeur in os.environ.items() if cle in GARDES}
    google = compte_google(secret)
    if google is not None:
        with open(os.path.join(maison, "oauth_creds.json"), "w", encoding="utf-8") as f:
            json.dump(google, f)
        env["GOOGLE_GENAI_USE_GCA"] = "true"
    else:
        regle["security"]["auth"]["selectedType"] = "gemini-api-key"
        env["GEMINI_API_KEY"] = secret.strip()
    with open(os.path.join(maison, "settings.json"), "w", encoding="utf-8") as f:
        json.dump(regle, f)
    chemin_systeme = os.path.join(dossier, "systeme.md")
    with open(chemin_systeme, "w", encoding="utf-8") as f:
        f.write(systeme)
    env.update({
        "HOME": dossier,
        "GEMINI_CLI_HOME": dossier,
        # FOU-10 : la consigne de HAL remplace celle de Gemini CLI.
        "GEMINI_SYSTEM_MD": chemin_systeme,
        "NO_COLOR": "1",
    })
    return env


def secret_rafraichi(dossier: str, secret: str) -> str | None:
    """Les identifiants Google, s'ils ont été renouvelés pendant la course."""
    if compte_google(secret) is None:
        return None
    try:
        with open(os.path.join(dossier, ".gemini", "oauth_creds.json"), encoding="utf-8") as f:
            neufs = json.load(f)
    except (OSError, ValueError):
        return None
    if not neufs.get("refresh_token") or neufs == compte_google(secret):
        return None
    return json.dumps(neufs)


# ---------------------------------------------------------------------------
# Lancer Gemini CLI, et lire ce qu'il rend
# ---------------------------------------------------------------------------

# Remplaçable dans les essais.
def _lancer(arguments: list[str], entree: str, env: dict, dossier: str,
            delai: float) -> subprocess.CompletedProcess:
    return subprocess.run(arguments, input=entree, env=env, cwd=os.path.join(dossier, "vide"),
                          capture_output=True, text=True, timeout=delai)


def _reprise(message: str) -> datetime | None:
    """L'heure de reprise quand Google la donne (« retry in 34s », « reset after 2h5m »)."""
    trouve = re.search(r"(?:retry in|reset (?:after|in))\s+((?:\d+(?:\.\d+)?[hms]\s*)+)",
                       message, re.IGNORECASE)
    if not trouve:
        return None
    secondes = sum(float(n) * {"h": 3600, "m": 60, "s": 1}[u]
                   for n, u in re.findall(r"(\d+(?:\.\d+)?)([hms])", trouve.group(1)))
    return datetime.now(UTC) + timedelta(seconds=max(secondes, 60))


def classer(message: str, code: int | None = None) -> Indisponible:
    """FOU-4 à FOU-6 : ce que dit une erreur de Gemini CLI. Le quota d'abord : son
    message invite aussi à « changer de méthode d'identification »."""
    bas = message.lower()
    if any(m in bas for m in ("429", "resource_exhausted", "quota", "rate limit")):
        return Indisponible("limite", f"Limite d'usage de Gemini : {message}"[:300],
                            _reprise(message))
    if code == SORTIE_IDENTIFICATION or any(m in bas for m in (
            "401", "403", "unauthenticated", "permission_denied", "invalid_grant",
            "api key not valid", "api_key_invalid", "authentication", "login", "auth method")):
        return Indisponible("jeton", f"Gemini refuse l'identification : {message}"[:300])
    return Indisponible("injoignable", f"Gemini CLI : {message}"[:300])


def lire(sortie: str, code: int, erreurs: str, passage: Passage) -> None:
    """Lit les événements (stream-json) d'un passage. Le texte rendu est celui que
    le modèle a écrit après son dernier outil."""
    texte: list[str] = []
    resultat = None
    for ligne in sortie.splitlines():
        ligne = ligne.strip()
        if not ligne.startswith("{"):
            continue
        try:
            evenement = json.loads(ligne)
        except ValueError:
            continue
        nature = evenement.get("type")
        if nature == "message" and evenement.get("role") == "assistant":
            texte.append(evenement.get("content") or "")
        elif nature == "tool_use":
            texte = []
        elif nature == "result":
            resultat = evenement
    if resultat is None:
        detail = (erreurs.strip().splitlines() or [f"sortie {code}"])[-1]
        raise classer(detail, code)
    stats = resultat.get("stats") or {}
    passage.entree += int(stats.get("input_tokens") or 0)
    passage.cache += int(stats.get("cached") or 0)
    passage.sortie += int(stats.get("output_tokens") or 0)
    passage.tours_modele += int(stats.get("tool_calls") or 0) + 1
    if resultat.get("status") != "success":
        erreur = resultat.get("error") or {}
        message = str(erreur.get("message") or erreur.get("type") or "erreur")
        if "max session turns" in message.lower():
            raise Arret("Borne de tours de Gemini CLI dépassée")
        raise classer(message, code)
    passage.texte = "".join(texte).strip()


def _passer(arguments: list[str], entree: str, env: dict, dossier: str, limite: float,
            passage: Passage) -> None:
    restant = limite - time.monotonic()
    if restant <= 1:
        raise Arret("Délai dépassé")
    try:
        fini = _lancer(arguments, entree, env, dossier, restant)
    except subprocess.TimeoutExpired:
        raise Arret("Délai dépassé") from None
    except OSError as erreur:
        raise Indisponible("injoignable", f"Gemini CLI absent du serveur : {erreur}") from erreur
    lire(fini.stdout or "", fini.returncode, fini.stderr or "", passage)


def _commande(modele_nom: str) -> list[str]:
    return [configuration().gemini_cli_commande, "-o", "stream-json", "-m", modele_nom]


def courir(etat: EtatCourse, systeme: str, premier: str, modele_nom: str, secret: str,
           limite: float, relecture: Callable[[str], str | None] = lambda texte: None
           ) -> Passage:
    """Une course entière, comme `course.courir` : la réponse, puis la relecture
    éventuelle dans la même session (COA-30)."""
    restant = limite - time.monotonic()
    if restant <= 1 or not course._place().acquire(timeout=max(restant - 1, 0)):
        raise Indisponible("injoignable", "Trop de courses en cours sur le serveur")
    dossier = tempfile.mkdtemp(prefix="hal-gemini-")
    jeton = course.ouvrir(etat)
    passage = Passage()
    try:
        env = preparer(dossier, secret, systeme, [o.nom for o in etat.permis if not o.cache],
                       jeton, etat.borne + 6)
        # Le premier message arrive par l'entrée : il dépasse ce qu'un argument porte.
        _passer(_commande(modele_nom) + ["-p", ""], premier, env, dossier, limite, passage)
        suite = relecture(passage.texte)
        if suite is not None:
            premier_texte = passage.texte
            _passer(_commande(modele_nom) + ["--resume", "latest", "-p", ""], suite, env,
                    dossier, limite, passage)
            if passage.texte.strip().strip(".").upper() == "OK":
                passage.texte = premier_texte
        if etat.arret and not etat.requalifiee:
            raise Arret(etat.arret)
        passage.secret_neuf = secret_rafraichi(dossier, secret)
        return passage
    finally:
        course.fermer(jeton)
        shutil.rmtree(dossier, ignore_errors=True)
        course._place().release()


def ecrire(secret: str, systeme: str, texte: str, modele_nom: str, delai: float) -> modele.Tour:
    """Un appel sans outils : l'essai d'un secret avant de le garder (FOU-18)."""
    limite = time.monotonic() + delai
    if not course._place().acquire(timeout=max(delai - 1, 0)):
        raise Indisponible("injoignable", "Trop de courses en cours sur le serveur")
    dossier = tempfile.mkdtemp(prefix="hal-gemini-")
    passage = Passage()
    try:
        env = preparer(dossier, secret, systeme, [], None)
        _passer(_commande(modele_nom) + ["-p", ""], texte, env, dossier, limite, passage)
    finally:
        shutil.rmtree(dossier, ignore_errors=True)
        course._place().release()
    return modele.Tour(texte=passage.texte, tokens_entree=passage.entree,
                       tokens_cache=passage.cache, tokens_sortie=passage.sortie,
                       arret="end_turn")


def essayer(secret: str) -> None:
    """FOU-18 : un appel minimal avant de garder un secret."""
    motif = secret_valide(secret)
    if motif:
        raise Indisponible("jeton", motif)
    tour = ecrire(secret, "Réponds seulement OK.", "OK ?", configuration().gemini_cli_modele,
                  90.0)
    if not tour.texte:
        raise Indisponible("injoignable", "Gemini CLI n'a rien répondu")
