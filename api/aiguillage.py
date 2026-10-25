"""Qui répond : le HAL du foyer, le HAL sport, ou les deux     (AIG-1 à AIG-7)

Un message à HAL part dans l'appli sans dire à qui il s'adresse. Ce module le
décide, dans cet ordre, et s'arrête au premier qui tranche :

    1. le contexte : l'onglet d'où part le message, l'élément joint      (AIG-2)
    2. les mots-clés de `coach/aiguillage.json`                           (AIG-3)
    3. la question que HAL vient de poser de lui-même                     (AIG-10)
    4. un appel très court au petit modèle, qui répond d'un mot           (AIG-4)

Si le petit modèle ne répond pas, l'appli demande à l'utilisateur : « Maison »
ou « Sport ». À ne pas confondre avec `api/coach/aiguillage.py`, qui choisit
les paquets du dossier sportif à joindre à un appel (DOS).
"""

import json
import logging
import re
import unicodedata
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

from api.config import configuration

LOG = logging.getLogger(__name__)

MAISON, SPORT, LES_DEUX = "maison", "sport", "les_deux"

# AIG-4 : un mot, vite. Au-delà, c'est l'utilisateur qui choisit.
DELAI_MODELE = 6.0

FICHIER = Path(__file__).resolve().parent.parent / "coach" / "aiguillage.json"

CONSIGNE_MODELE = """Une application a deux assistants. Celui de la maison s'occupe des \
tâches ménagères, du planning du foyer, des absences et des voyages. Celui du sport s'occupe \
des séances, de l'entraînement, de la santé et du corps. Lis le message et réponds d'un seul \
mot : maison, sport, ou les_deux s'il demande clairement quelque chose à chacun. Un message \
qui ne parle ni de l'un ni de l'autre (un bonjour, un merci) : aucun. Rien d'autre."""


@dataclass
class Choix:
    """Où va le message, et ce qui l'a décidé (AIG-7). `hal` vide : à demander."""
    hal: str | None
    par: str


def sans_accents(texte: str) -> str:
    decompose = unicodedata.normalize("NFD", texte.lower())
    return "".join(c for c in decompose if unicodedata.category(c) != "Mn")


def _propre(texte: str) -> str:
    return " " + re.sub(r"[^a-z0-9]+", " ", sans_accents(texte)).strip() + " "


@lru_cache
def mots() -> dict[str, list[str]]:
    """Les mots de chaque côté, les plus longs d'abord : « courses à pied » passe
    avant « courses »."""
    lu = json.loads(FICHIER.read_text(encoding="utf-8"))
    return {cote: sorted({_propre(m).strip() for m in lu.get(cote, []) if m.strip()},
                         key=len, reverse=True)
            for cote in (MAISON, SPORT)}


def par_contexte(ecran: str | None, id_occurrence: int | None = None,
                 lundi: object = None) -> str | None:
    """AIG-2 : une séance ou une semaine jointe, ou l'onglet Sport : le sport.
    L'onglet Maison : la maison. Aujourd'hui et Réglages ne tranchent pas."""
    if id_occurrence is not None or lundi is not None:
        return SPORT
    onglet = sans_accents((ecran or "").split("·")[0]).strip()
    if onglet.startswith("sport"):
        return SPORT
    if onglet.startswith("maison"):
        return MAISON
    return None


def par_mots(texte: str) -> str | None:
    """AIG-3 : un côté l'emporte s'il a des mots et l'autre aucun ; des mots des
    deux côtés donnent « les deux ». Une expression trouvée est retirée du texte
    avant de chercher les plus courtes : « courses à pied » n'est pas « courses »."""
    reste = _propre(texte)
    trouves = {MAISON: False, SPORT: False}
    tous = sorted(((m, cote) for cote, liste in mots().items() for m in liste),
                  key=lambda x: len(x[0]), reverse=True)
    for mot, cote in tous:
        cible = f" {mot} "
        if cible in reste:
            trouves[cote] = True
            reste = reste.replace(cible, " | ")
    if trouves[MAISON] and trouves[SPORT]:
        return LES_DEUX
    if trouves[MAISON]:
        return MAISON
    if trouves[SPORT]:
        return SPORT
    return None


def lire_le_mot(reponse: str) -> str | None:
    """Un des trois mots ; « aucun », ou autre chose, rend None : on demande (AIG-4)."""
    propre = sans_accents(reponse or "").strip().strip(".").replace(" ", "_")
    for cote in (LES_DEUX, MAISON, SPORT):
        if propre.startswith(cote):
            return cote
    return None


# AIG-10 : les moments où HAL écrit de lui-même pour poser une question.
MOMENTS_QUESTION = ("presence", "absent", "soiree", "meteo")
QUESTION_VAUT_HEURES = 12


def question_en_attente(id_utilisateur: int) -> str | None:
    """AIG-10 : le HAL dont le dernier message est une question restée sans
    réponse, de moins de douze heures."""
    from api.base import un_seul
    ligne = un_seul(
        """SELECT auteur, moment, hal,
                  quand > now() - make_interval(hours => %(h)s) AS recente
             FROM echange WHERE id_utilisateur = %(u)s
            ORDER BY id_echange DESC LIMIT 1""",
        {"u": id_utilisateur, "h": QUESTION_VAUT_HEURES})
    if ligne is None or ligne["auteur"] != "coach" or not ligne["recente"] \
            or ligne["moment"] not in MOMENTS_QUESTION:
        return None
    return MAISON if ligne["hal"] == "foyer" else SPORT


def par_modele(texte: str, id_utilisateur: int) -> str | None:
    """AIG-4 : le petit modèle ne reçoit que le message. Rend None s'il ne répond
    pas, ou pas d'un des trois mots."""
    conf = configuration()
    if not conf.coach_modele_aiguillage:
        return None
    from api.coach import fournisseurs, modele
    try:
        # FOU-15 : par l'API du compte ou du serveur ; Claude Code démarre trop lentement.
        tour = fournisseurs.ecrire(id_utilisateur, CONSIGNE_MODELE, texte[:2000],
                                   conf.coach_modele_aiguillage, 10, DELAI_MODELE,
                                   abonnement=False)
    except modele.ModeleInjoignable as erreur:
        LOG.info("Aiguillage par le modèle impossible : %s", erreur)
        return None
    return lire_le_mot(tour.texte)


def choisir(texte: str, id_utilisateur: int, ecran: str | None = None,
            id_occurrence: int | None = None, lundi: object = None) -> Choix:
    """AIG-1 : le contexte, puis les mots, puis le petit modèle.

    Un élément joint tranche seul. L'onglet tranche aussi, sauf si les mots
    parlent de l'autre côté : « décale ma séance et la litière », écrit depuis
    Maison, va aux deux.
    """
    if id_occurrence is not None or lundi is not None:
        return Choix(SPORT, "contexte")
    onglet = par_contexte(ecran)
    selon_les_mots = par_mots(texte)
    if onglet:
        if selon_les_mots and selon_les_mots != onglet:
            return Choix(LES_DEUX, "mots")
        return Choix(onglet, "contexte")
    if selon_les_mots:
        return Choix(selon_les_mots, "mots")
    question = question_en_attente(id_utilisateur)
    if question:
        return Choix(question, "question")
    hal = par_modele(texte, id_utilisateur)
    if hal:
        return Choix(hal, "modele")
    return Choix(None, "utilisateur")
