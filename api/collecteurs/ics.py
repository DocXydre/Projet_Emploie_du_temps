"""Collecte des contraintes dures depuis des flux iCalendar.

Deux sources, deux profils, un seul collecteur.

**Profil `ade`** — emploi du temps universitaire (Université de Lorraine). Le
flux a trois particularités qu'il faut connaître avant de lire le code :

1. *Chaque cours apparaît deux fois, avec le même UID.* Une version dépouillée
   (LOCATION et DESCRIPTION vides) et une version enrichie qui porte la salle et
   l'enseignant. Réconcilier bêtement par UID ferait gagner la dernière lue, donc
   parfois la version vide : la salle disparaîtrait du calendrier. On fusionne
   donc par UID en gardant la version la plus informative.
2. *La salle n'est pas toujours attribuée.* « SALLE A DEFINIR » est courant pour
   les semaines à venir, et le champ est vide plus loin dans le semestre.
3. *Le libellé porte le groupe de TD*, avec une orthographe variable : « gpe1 »,
   « gpe 1 », « gpe 2 ».

**Profil `easyatwork`** — planning McDonald's. Beaucoup plus simple : un UID
stable par shift, pas de doublon, et un titre toujours identique. La seule
subtilité est que le flux contient plusieurs mois de passé, qu'il ne sert à rien
de recharger indéfiniment.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field
from datetime import UTC, date, datetime, timedelta
from urllib.parse import parse_qsl, urlencode, urlparse, urlunparse

import httpx
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

GROUPE = re.compile(r"\b(?:gpe|groupe|gr)\s*([0-9])\b", re.IGNORECASE)

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


PROFILS = {
    "ade": _seance_ade,
    "easyatwork": _seance_easyatwork,
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


def analyser(texte_ics: str, profil: str = "ade") -> list[Seance]:
    """Transforme le flux en séances, doublons d'UID fusionnés."""
    normaliser = PROFILS.get(profil)
    if normaliser is None:
        raise ValueError(f"Profil de collecte inconnu : {profil}")

    calendrier = Calendar.from_ical(texte_ics)
    par_uid: dict[str, Seance] = {}
    ignorees = 0

    for evenement in calendrier.walk("VEVENT"):
        uid = _texte(evenement, "UID")
        debut = _instant(evenement, "DTSTART")
        fin = _instant(evenement, "DTEND")
        resume = _texte(evenement, "SUMMARY")

        if not (uid and debut and fin and resume) or fin <= debut:
            ignorees += 1
            continue

        seance = normaliser(uid, resume, debut, fin,
                            _texte(evenement, "LOCATION"),
                            _texte(evenement, "DESCRIPTION"))

        # Fusion : entre deux versions du même cours, on garde celle qui
        # apporte le plus d'information.
        existante = par_uid.get(uid)
        if existante is None or seance.richesse > existante.richesse:
            par_uid[uid] = seance

    if ignorees:
        LOG.warning("%d événement(s) ICS ignoré(s), incomplets ou mal formés", ignorees)

    return sorted(par_uid.values(), key=lambda s: s.debut)


# ---------------------------------------------------------------------------
# Filtrage
# ---------------------------------------------------------------------------

def langues_suivies(configuration: dict) -> list[str]:
    """Langues réellement suivies, une fois l'alternance prise en compte.

    En alternance, l'espagnol saute : c'est une règle de la maquette, pas une
    préférence, d'où sa place dans la configuration plutôt que dans le code.
    """
    suivies = [langue.lower() for langue in configuration.get("langues_suivies", [])]
    if configuration.get("alternance"):
        suivies = [langue for langue in suivies if langue != "espagnol"]
    return suivies


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

    groupe_voulu = configuration.get("groupe")
    if groupe_voulu and seance.groupe and seance.groupe != groupe_voulu:
        return False, f"groupe {seance.groupe}"

    return True, ""


# ---------------------------------------------------------------------------
# Récupération
# ---------------------------------------------------------------------------

def url_fenetre_glissante(url: str, horizon_jours: int, aujourd_hui: date | None = None) -> str:
    """Recale les bornes de dates du flux sur une fenêtre glissante.

    L'URL de l'ADE contient des dates fixes : sans ce recalage, le flux se
    viderait au fil du semestre. Les flux qui n'ont pas ces paramètres, comme
    celui d'Easy at Work, ne sont pas modifiés.
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

    for seance in analyser(brut, profil):
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
