"""Collecte des emplois du temps depuis des flux iCalendar.

Deux profils, un seul collecteur.

`ade` — emploi du temps universitaire. Le flux a trois particularités :
chaque cours y apparaît deux fois sous le même UID, une version vide et une
version portant la salle et l'enseignant ; la salle vaut parfois « SALLE A
DEFINIR » ; le groupe de TD s'écrit tantôt « gpe1 », tantôt « gpe 1 ».

`easyatwork` — planning McDonald's. Un UID stable par service, pas de doublon,
mais plusieurs mois de passé qu'il est inutile de recharger.

`perso` — calendrier tenu à la main. Rien à normaliser, mais tout à
développer : une application de calendrier écrit « tous les lundis » en une
seule ligne, là où l'ADE publie chaque séance séparément.
"""

from __future__ import annotations

import logging
import re
import unicodedata
from dataclasses import dataclass, field
from datetime import UTC, date, datetime, time, timedelta
from urllib.parse import parse_qsl, urlencode, urlparse, urlunparse
from zoneinfo import ZoneInfo

import httpx
import recurring_ical_events
from icalendar import Calendar

LOG = logging.getLogger(__name__)

# --- Profil ADE -------------------------------------------------------------

# « SALLE A DEFINIR » n'est pas une salle : c'est l'absence de salle.
SALLE_INCONNUE = re.compile(r"^\s*salle\s+a\s+definir\s*$", re.IGNORECASE)

# « (49 Places) », « ( 49 Places) » : la capacité n'intéresse personne.
CAPACITE = re.compile(r"\s*\(\s*\d+\s*places?\s*\)", re.IGNORECASE)

# Un enseignant s'écrit NOM Prénom : patronyme en capitales, prénom capitalisé.
# Le motif écarte volontairement « Enseignant 1 », qui est l'anonymisation
# utilisée par le flux public quand le nom n'est pas publiable.
ENSEIGNANT = re.compile(r"^[A-ZÀ-ÝŒ][A-ZÀ-ÝŒ'’\- ]{2,}\s+[A-ZÀ-ÝŒ][a-zà-ÿœ'’\-]+$")

# Codes de maquette : « 7JEMEN11PO|7JMEN1102 ».
CODE_MAQUETTE = re.compile(r"^[A-Z0-9|]+$")

# « grp » est placé avant « gr » : l'alternance retient le premier motif qui
# correspond, et « gr » seul ne reconnaissait pas « Grp 2 ».
GROUPE = re.compile(r"\b(?:gpe|groupe|grp|gr)\s*([0-9])\b", re.IGNORECASE)

# --- Profil Easy at Work ----------------------------------------------------

# « Shift: McDonald's NANCY CENTRE »
SHIFT = re.compile(r"^\s*shift\s*:\s*(?P<enseigne>.+?)\s*$", re.IGNORECASE)


@dataclass
class Seance:
    """Une occupation normalisée, prête à être écrite en base."""

    cle_externe: str
    libelle: str
    debut: datetime
    fin: datetime
    lieu: str | None = None
    details: str | None = None
    groupe: int | None = None
    richesse: int = field(default=0)
    journee_entiere: bool = False


# ---------------------------------------------------------------------------
# Extraction, profil ADE
# ---------------------------------------------------------------------------

def nettoyer_salle(location: str | None) -> str | None:
    if not location:
        return None

    # La virgule est échappée dans le flux et sépare plusieurs ressources :
    # « 105,Salle 104 (49 Places) ». Les parties purement numériques sont des
    # codes de bâtiment, pas des salles.
    salles = []
    for partie in location.replace("\\,", ",").split(","):
        partie = CAPACITE.sub("", partie.strip()).strip()
        if not partie or partie.isdigit() or SALLE_INCONNUE.match(partie):
            continue
        salles.append(partie)

    return " / ".join(salles) or None


def extraire_enseignant(description: str | None) -> str | None:
    if not description:
        return None

    for ligne in description.replace("\\n", "\n").split("\n"):
        ligne = ligne.strip()
        if not ligne or ligne.startswith("(Modifié") or "|" in ligne:
            continue
        if CODE_MAQUETTE.match(ligne):
            continue
        if ENSEIGNANT.match(ligne):
            return ligne
    return None


def nettoyer_libelle(resume: str) -> str:
    """Retire le bruit du titre ADE, en gardant le type de cours."""
    libelle = GROUPE.sub("", resume.strip())
    # « CM EC Système » : « EC » désigne l'élément constitutif, sans intérêt ici.
    libelle = re.sub(r"\bEC\b\s*", "", libelle)
    return re.sub(r"\s{2,}", " ", libelle).strip(" -:")


def groupe_de(resume: str) -> int | None:
    trouve = GROUPE.search(resume)
    return int(trouve.group(1)) if trouve else None


def _seance_ade(uid: str, resume: str, debut: datetime, fin: datetime,
                location: str | None, description: str | None) -> Seance:
    salle = nettoyer_salle(location)
    enseignant = extraire_enseignant(description)

    morceaux = []
    if salle:
        morceaux.append(f"Salle : {salle}")
    if enseignant:
        morceaux.append(f"Enseignant : {enseignant}")

    return Seance(
        cle_externe=uid,
        libelle=nettoyer_libelle(resume),
        debut=debut,
        fin=fin,
        lieu=salle,
        details="\n".join(morceaux) or None,
        groupe=groupe_de(resume),
        # Sert à départager deux versions du même UID.
        richesse=(1 if salle else 0) + (1 if enseignant else 0),
    )


# ---------------------------------------------------------------------------
# Extraction, profil Easy at Work
# ---------------------------------------------------------------------------

def _seance_easyatwork(uid: str, resume: str, debut: datetime, fin: datetime,
                       location: str | None, description: str | None) -> Seance:
    trouve = SHIFT.match(resume)
    enseigne = trouve.group("enseigne") if trouve else resume.strip()

    # « McDonald's NANCY CENTRE » : l'enseigne fait le libellé, la ville le lieu.
    mots = enseigne.split()
    if len(mots) > 1 and mots[-1].isupper() and mots[-2].isupper():
        libelle, lieu = " ".join(mots[:-2]), " ".join(mots[-2:])
    else:
        libelle, lieu = enseigne, None

    return Seance(
        cle_externe=uid,
        libelle=f"Shift {libelle}".strip(),
        debut=debut,
        fin=fin,
        lieu=lieu,
        details=None,
        richesse=1,
    )


# --- Profil calendrier personnel --------------------------------------------

def _seance_perso(uid: str, resume: str, debut: datetime, fin: datetime,
                  location: str | None, description: str | None) -> Seance:
    """Un événement saisi à la main dans une application de calendrier.

    Aucun nettoyage : on reprend le libellé tel quel. Les profils ADE et
    Easy at Work normalisent parce qu'ils lisent des flux générés.
    """
    return Seance(
        cle_externe=uid,
        libelle=resume.strip(),
        debut=debut,
        fin=fin,
        lieu=(location or "").strip() or None,
        details=(description or "").strip() or None,
        richesse=1,
    )


PROFILS = {
    "ade": _seance_ade,
    "easyatwork": _seance_easyatwork,
    "perso": _seance_perso,
}


# ---------------------------------------------------------------------------
# Analyse
# ---------------------------------------------------------------------------

def _texte(evenement, champ: str) -> str | None:
    valeur = evenement.get(champ)
    return str(valeur) if valeur is not None else None


def _instant(evenement, champ: str) -> datetime | None:
    valeur = evenement.get(champ)
    if valeur is None:
        return None
    brut = valeur.dt
    # Un événement journée entière n'a pas sa place dans un emploi du temps.
    return brut if isinstance(brut, datetime) else None


def _richesse_brute(evenement) -> int:
    """Compte l'information portée par une version d'un événement."""
    return sum(1 for champ in ("LOCATION", "DESCRIPTION") if evenement.get(champ))


def _dedoublonner(calendrier: Calendar) -> Calendar:
    """Ne garde qu'une version de chaque événement, la plus fournie.

    L'ADE publie chaque cours deux fois sous le même UID : une version vide et
    une version portant la salle et l'enseignant. Le développement des
    récurrences n'en garderait qu'une, et pas forcément la bonne. On tranche
    donc avant lui.

    Une série et l'occurrence qu'on en a déplacée partagent leur UID mais pas
    leur RECURRENCE-ID : ce sont deux entrées distinctes, pas un doublon.
    """
    meilleurs: dict[tuple[str, str], int] = {}
    for evenement in calendrier.walk("VEVENT"):
        cle = (str(evenement.get("UID")), str(evenement.get("RECURRENCE-ID", "")))
        connu = meilleurs.get(cle)
        if connu is None or _richesse_brute(evenement) > _richesse_brute(connu):
            meilleurs[cle] = evenement

    gardes = {id(evenement) for evenement in meilleurs.values()}
    calendrier.subcomponents = [
        composant for composant in calendrier.subcomponents
        if composant.name != "VEVENT" or id(composant) in gardes
    ]
    return calendrier


def _uids_recurrents(calendrier: Calendar) -> set[str]:
    """UID des séries. Leurs occurrences ont besoin d'une clé externe datée."""
    return {
        str(evenement.get("UID"))
        for evenement in calendrier.walk("VEVENT")
        if evenement.get("RRULE") or evenement.get("RDATE")
        or evenement.get("RECURRENCE-ID")
    }


def _instant_ics(valeur) -> datetime | None:
    """Ramène un DTSTART, date ou horaire, à un instant comparable."""
    if valeur is None:
        return None
    brut = valeur.dt
    if not isinstance(brut, datetime):
        return datetime.combine(brut, time.min, tzinfo=UTC)
    return brut if brut.tzinfo else brut.replace(tzinfo=UTC)


def _bornes_simples(calendrier: Calendar) -> tuple[datetime, datetime] | None:
    """Étendue des événements sans récurrence, ou None s'il n'y en a aucun.

    Elle sert à élargir la fenêtre de développement. Le flux McDonald's traîne
    plusieurs mois de passé : si on ne les développait pas, le filtre d'horizon
    n'aurait rien à écarter et ne compterait rien. Une collecte qui jette des
    données sans dire combien est indébogable.

    Les séries, elles, restent bornées à la fenêtre demandée : « tous les
    lundis » n'a pas de fin, et les développer plus loin ne renseigne personne.
    """
    instants = [
        _instant_ics(evenement.get("DTSTART"))
        for evenement in calendrier.walk("VEVENT")
        if not (evenement.get("RRULE") or evenement.get("RDATE"))
    ]
    instants = [instant for instant in instants if instant is not None]
    return (min(instants), max(instants)) if instants else None


def _fenetre_par_defaut(calendrier: Calendar) -> tuple[datetime, datetime]:
    """Bornes déduites du fichier, pour les appels qui n'en donnent pas.

    Développer une récurrence exige des bornes : « tous les lundis » n'a pas de
    fin. Faute de mieux, on prend l'étendue du fichier élargie d'un an.
    """
    debuts = [
        instant for instant in
        (_instant_ics(evenement.get("DTSTART")) for evenement in calendrier.walk("VEVENT"))
        if instant is not None
    ]

    if not debuts:
        maintenant = datetime.now(UTC)
        return maintenant, maintenant + timedelta(days=1)
    return min(debuts) - timedelta(days=1), max(debuts) + timedelta(days=400)


def analyser(texte_ics: str, profil: str = "ade",
             debut: datetime | None = None, fin: datetime | None = None,
             fuseau: str = "Europe/Paris") -> list[Seance]:
    """Transforme le flux en séances, récurrences développées.

    Chaque occurrence d'une série devient une séance à part entière, avec ses
    propres horaires. Les exceptions et les séances déplacées sont prises en
    compte : c'est le format iCalendar qui les décrit, pas nous.
    """
    normaliser = PROFILS.get(profil)
    if normaliser is None:
        raise ValueError(f"Profil de collecte inconnu : {profil}")

    calendrier = _dedoublonner(Calendar.from_ical(texte_ics))
    if debut is None or fin is None:
        debut, fin = _fenetre_par_defaut(calendrier)
    else:
        # Les événements simples hors fenêtre sont développés quand même, pour
        # que le filtre d'horizon puisse les écarter et les compter.
        bornes = _bornes_simples(calendrier)
        if bornes is not None:
            debut, fin = min(debut, bornes[0]), max(fin, bornes[1] + timedelta(days=1))

    recurrents = _uids_recurrents(calendrier)
    zone = ZoneInfo(fuseau)

    seances: list[Seance] = []
    ignorees = 0

    for occurrence in recurring_ical_events.of(calendrier).between(debut, fin):
        uid = _texte(occurrence, "UID")
        resume = _texte(occurrence, "SUMMARY")
        depart = occurrence.get("DTSTART")
        arrivee = occurrence.get("DTEND")

        if not (uid and resume and depart is not None and arrivee is not None):
            ignorees += 1
            continue

        # Une journée entière est écrite en dates, pas en horaires. On la ramène
        # à minuit dans le fuseau d'affichage : la base ne stocke que des
        # instants, et « le 3 octobre » commence à une heure différente selon
        # l'endroit d'où on le lit.
        entiere = not isinstance(depart.dt, datetime)
        if entiere:
            ouverture = datetime.combine(depart.dt, time.min, tzinfo=zone)
            fermeture = datetime.combine(arrivee.dt, time.min, tzinfo=zone)
        else:
            ouverture, fermeture = depart.dt, arrivee.dt

        if fermeture <= ouverture:
            ignorees += 1
            continue

        seance = normaliser(uid, resume, ouverture, fermeture,
                            _texte(occurrence, "LOCATION"),
                            _texte(occurrence, "DESCRIPTION"))
        seance.journee_entiere = entiere

        # Toutes les occurrences d'une série portent le même UID. Sans la date
        # dans la clé externe, elles s'écraseraient les unes les autres en base
        # et il n'en resterait qu'une.
        if uid in recurrents:
            seance.cle_externe = f"{uid}#{ouverture:%Y%m%dT%H%M%S}"

        seances.append(seance)

    if ignorees:
        LOG.warning("%d événement(s) ICS ignoré(s), incomplets ou mal formés", ignorees)

    return sorted(seances, key=lambda s: s.debut)


# ---------------------------------------------------------------------------
# Filtrage
# ---------------------------------------------------------------------------

def langues_suivies(configuration: dict) -> list[str]:
    """Langues réellement suivies, une fois l'alternance prise en compte.

    En alternance, l'espagnol n'est pas suivi. La règle vient de la maquette
    et se règle dans la configuration de la source.
    """
    suivies = [langue.lower() for langue in configuration.get("langues_suivies", [])]
    if configuration.get("alternance"):
        suivies = [langue for langue in suivies if langue != "espagnol"]
    return suivies


def sans_accent(texte: str) -> str:
    decompose = unicodedata.normalize("NFD", texte)
    return "".join(c for c in decompose if unicodedata.category(c) != "Mn")


def a_garder(seance: Seance, configuration: dict) -> tuple[bool, str]:
    """Décide si une séance concerne bien l'utilisateur.

    Renvoie aussi le motif du rejet : une collecte qui jette des données sans
    dire pourquoi est indébogable.
    """
    minuscule = seance.libelle.lower()

    possibles = [langue.lower() for langue in configuration.get("langues_possibles", [])]
    suivies = langues_suivies(configuration)

    for langue in possibles:
        if langue in minuscule and langue not in suivies:
            motif = "alternance" if configuration.get("alternance") and langue == "espagnol" \
                else "langue non suivie"
            return False, f"{motif} ({langue})"

    # COL-17 : les UE au choix. L'ADE publie toutes les options dans le même
    # flux, celle qu'on suit comme celle qu'on a laissée. Le libellé est comparé
    # sans accent, l'ADE ne les écrivant pas toujours.
    normalise = sans_accent(minuscule)
    for ecarte in configuration.get("cours_ecartes", []):
        if sans_accent(ecarte.lower()) in normalise:
            return False, f"cours non suivi ({ecarte})"

    groupe_voulu = configuration.get("groupe")
    if groupe_voulu and seance.groupe and seance.groupe != groupe_voulu:
        return False, f"groupe {seance.groupe}"

    return True, ""


# ---------------------------------------------------------------------------
# Récupération
# ---------------------------------------------------------------------------

def url_fenetre_glissante(url: str, horizon_jours: int, aujourd_hui: date | None = None) -> str:
    """Recale les bornes de dates du flux sur une fenêtre glissante.

    L'URL de l'ADE contient des dates de début et de fin fixes. On les décale
    à chaque collecte pour que le flux suive le semestre. Les URL sans ces
    paramètres, comme celle d'Easy at Work, sont renvoyées telles quelles.
    """
    morceaux = urlparse(url)
    params = dict(parse_qsl(morceaux.query))
    if "firstDate" not in params and "lastDate" not in params:
        return url

    aujourd_hui = aujourd_hui or date.today()
    params["firstDate"] = aujourd_hui.isoformat()
    params["lastDate"] = (aujourd_hui + timedelta(days=horizon_jours)).isoformat()
    return urlunparse(morceaux._replace(query=urlencode(params)))


def recuperer(url: str, horizon_jours: int = 60, delai: float = 20.0) -> str:
    reponse = httpx.get(url_fenetre_glissante(url, horizon_jours),
                        timeout=delai, follow_redirects=True)
    reponse.raise_for_status()
    return reponse.text


def collecter(url: str, configuration: dict, texte_ics: str | None = None,
              maintenant: datetime | None = None) -> dict:
    """Récupère, analyse et filtre. Ne touche pas à la base.

    `texte_ics` permet de rejouer un flux déjà téléchargé, ce dont les tests se
    servent pour ne pas dépendre du réseau.
    """
    profil = configuration.get("profil", "ade")
    horizon = int(configuration.get("horizon_jours", 60))
    historique = int(configuration.get("historique_jours", 7))
    maintenant = maintenant or datetime.now(UTC)

    brut = texte_ics if texte_ics is not None else recuperer(url, horizon)

    plancher = maintenant - timedelta(days=historique)
    plafond = maintenant + timedelta(days=horizon)

    gardees, rejets = [], {}

    # Les bornes servent d'abord à développer les récurrences : sans elles,
    # « tous les lundis » n'a pas de fin.
    for seance in analyser(brut, profil, plancher, plafond,
                           configuration.get("fuseau", "Europe/Paris")):
        # Le flux McDonald's traîne plusieurs mois de passé : inutile de les
        # recharger à chaque collecte.
        if seance.fin < plancher:
            rejets["hors horizon (passé)"] = rejets.get("hors horizon (passé)", 0) + 1
            continue
        if seance.debut > plafond:
            rejets["hors horizon (futur)"] = rejets.get("hors horizon (futur)", 0) + 1
            continue

        garder, motif = a_garder(seance, configuration)
        if garder:
            gardees.append(seance)
        else:
            rejets[motif] = rejets.get(motif, 0) + 1

    return {"seances": gardees, "lues": len(gardees) + sum(rejets.values()), "rejets": rejets}
