"""Relevé des créneaux publiés par le SUAPS.

Le service change ses horaires d'une semaine à l'autre. Les saisir à la main
revient à se tromper dès le lundi suivant, et on ne s'en aperçoit qu'une fois
devant la porte.

La page est rendue côté serveur : une requête HTTP suffit, sans navigateur. Elle
liste une ligne par séance, avec le site, le jour, les horaires, la période et
le public visé.

    <div class="session__row" id="js-session-1088">
      <div class="session__row-site"><h3 class="s">Piscine ... Nancy</h3>...</div>
      <div class="session__row-date">
        <p class="s js-session-title">Lundi de 12:30 à 13:30</p>
        <p>Toute l'année</p>
        <p>Tout public</p>
      </div>
      ...
    </div>

L'analyse est volontairement tolérante : ce qu'elle ne sait pas lire est compté
et signalé, pas deviné. Une page refondue doit se voir dans un bilan, pas se
traduire par un planning silencieusement faux.
"""

from __future__ import annotations

import html
import logging
import re
import unicodedata
from dataclasses import dataclass

import httpx

LOG = logging.getLogger(__name__)

JOURS = {
    "lundi": 1, "mardi": 2, "mercredi": 3, "jeudi": 4,
    "vendredi": 5, "samedi": 6, "dimanche": 7,
}

# Une ligne de séance. On découpe là-dessus plutôt que d'analyser tout le
# document : la classe est stable et porte le sens.
LIGNE = re.compile(r'class="[^"]*session__row[ "]', re.IGNORECASE)

SITE = re.compile(r'session__row-site.*?<h3[^>]*>(.*?)</h3>', re.IGNORECASE | re.DOTALL)
TITRE = re.compile(r'js-session-title[^>]*>(.*?)</p>', re.IGNORECASE | re.DOTALL)
PARAGRAPHES = re.compile(r'<p[^>]*>(.*?)</p>', re.IGNORECASE | re.DOTALL)

HORAIRE = re.compile(
    r"(lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche)\s+de\s+"
    r"(\d{1,2})\s*[h:]\s*(\d{2})\s+(?:à|a)\s+(\d{1,2})\s*[h:]\s*(\d{2})",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class Creneau:
    jour: int
    debut: str
    fin: str
    site: str
    periode: str
    public: str


def _texte(brut: str) -> str:
    """Balises retirées, entités décodées, espaces resserrés."""
    sans_balises = re.sub(r"<[^>]+>", " ", brut)
    return re.sub(r"\s+", " ", html.unescape(sans_balises)).strip()


def _sans_accent(texte: str) -> str:
    decompose = unicodedata.normalize("NFD", texte)
    return "".join(c for c in decompose if unicodedata.category(c) != "Mn")


def analyser(page: str) -> tuple[list[Creneau], dict[str, int]]:
    """Toutes les séances de la page, et le compte de ce qui n'a pas été lu."""
    morceaux = LIGNE.split(page)[1:]
    creneaux: list[Creneau] = []
    rejets: dict[str, int] = {}

    for morceau in morceaux:
        site = SITE.search(morceau)
        titre = TITRE.search(morceau)
        if titre is None:
            rejets["sans horaire"] = rejets.get("sans horaire", 0) + 1
            continue

        lu = HORAIRE.search(_texte(titre.group(1)))
        if lu is None:
            rejets["horaire illisible"] = rejets.get("horaire illisible", 0) + 1
            continue

        # Les deux paragraphes qui suivent le titre : période puis public.
        suites = [_texte(p) for p in PARAGRAPHES.findall(morceau)]
        suites = [s for s in suites if s]
        periode = suites[1] if len(suites) > 1 else ""
        public = suites[2] if len(suites) > 2 else ""

        creneaux.append(Creneau(
            jour=JOURS[_sans_accent(lu.group(1)).lower()],
            debut=f"{int(lu.group(2)):02d}:{lu.group(3)}",
            fin=f"{int(lu.group(4)):02d}:{lu.group(5)}",
            site=_texte(site.group(1)) if site else "",
            periode=periode,
            public=public,
        ))

    return creneaux, rejets


def retenir(creneaux: list[Creneau], configuration: dict) -> tuple[list[Creneau], dict]:
    """Ne garde que le bon site et les publics acceptés.

    La page mêle Nancy et Metz, et des séances réservées à certains publics. Un
    filtre absent laisse tout passer : c'est le comportement voulu pour un lieu
    qui n'aurait qu'une seule offre.
    """
    site_voulu = _sans_accent((configuration.get("site") or "").lower())
    publics = [_sans_accent(p.lower()) for p in configuration.get("publics", [])]

    gardes, rejets = [], {}
    for creneau in creneaux:
        if site_voulu and site_voulu not in _sans_accent(creneau.site.lower()):
            rejets["autre site"] = rejets.get("autre site", 0) + 1
            continue

        public = _sans_accent(creneau.public.lower())
        if publics and not any(p in public for p in publics):
            motif = f"public non concerné ({creneau.public})"
            rejets[motif] = rejets.get(motif, 0) + 1
            continue

        gardes.append(creneau)

    return gardes, rejets


def recuperer(url: str, delai: float = 20.0) -> str:
    reponse = httpx.get(url, timeout=delai, follow_redirects=True,
                        headers={"User-Agent": "planif/1.0 (usage personnel)"})
    reponse.raise_for_status()
    return reponse.text


def relever(url: str, configuration: dict, page: str | None = None) -> dict:
    """Récupère et analyse. Ne touche pas à la base.

    `page` permet de rejouer un document déjà téléchargé, sans réseau.
    """
    brut = page if page is not None else recuperer(url)

    tous, rejets = analyser(brut)
    gardes, ecartes = retenir(tous, configuration)
    rejets.update(ecartes)

    return {
        "creneaux": gardes,
        "lues": len(tous) + sum(rejets.get(m, 0) for m in ("sans horaire",
                                                           "horaire illisible")),
        "retenues": len(gardes),
        "rejets": rejets,
    }
