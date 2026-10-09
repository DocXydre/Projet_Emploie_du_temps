"""Quels paquets du dossier joindre à un appel, et en quel détail   (DOS-2 à DOS-6)

Trois sources, dans cet ordre, la plus généreuse l'emporte pour un paquet :

    1. le moment : un plan a besoin de la planification en entier, une
       synthèse de son résumé (`moments` dans `coach/paquets.json`)
    2. les disciplines en jeu : celles des objectifs actifs, et celle de la
       séance dont on parle (`disciplines`, `detail_discipline`)
    3. le texte de l'utilisateur, quand il y en a un : un petit modèle rapide
       (Haiku) le lit et choisit. S'il ne répond pas, les mots-clés.

Le choix ne retire jamais le socle, et le coach peut toujours lire un chapitre
de plus avec `lire_chapitre` : un mauvais aiguillage coûte un tour, pas une
erreur.
"""

import logging
import re
import unicodedata
from dataclasses import dataclass, field

from api.base import lister, un_seul
from api.coach import dossier, modele
from api.config import configuration

LOG = logging.getLogger(__name__)

# Le choix d'un message libre doit être rapide : au-delà, les mots-clés.
DELAI_AIGUILLAGE = 8.0

_RANG = {None: 0, "resume": 1, "complet": 2}


@dataclass
class Aiguillage:
    choix: dict[str, str] = field(default_factory=dict)
    # haiku, mots, ou vide si seul le moment a parlé.
    par: str = ""
    tokens_entree: int = 0
    tokens_sortie: int = 0

    def ajouter(self, code: str, detail: str) -> None:
        if code not in dossier.paquets() or detail not in dossier.DETAILS:
            return
        if _RANG[detail] > _RANG[self.choix.get(code)]:
            self.choix[code] = detail

    def en_liste(self) -> list[str]:
        """Pour l'appel enregistré : « course:complet », dans l'ordre du réglage."""
        return [f"{code}:{self.choix[code]}" for code in dossier.paquets()
                if code in self.choix]


def sans_accents(texte: str) -> str:
    decompose = unicodedata.normalize("NFD", texte.lower())
    return "".join(c for c in decompose if unicodedata.category(c) != "Mn")


def par_mots_cles(texte: str) -> dict[str, str]:
    """DOS-5 : un mot-clé du paquet dans le texte, et le paquet part en résumé."""
    propre = " " + re.sub(r"[^a-z0-9]+", " ", sans_accents(texte)) + " "
    choix = {}
    for code, paquet in dossier.paquets().items():
        for mot in paquet.get("mots", []):
            if f" {sans_accents(mot)} " in propre or (
                    len(mot) >= 5 and f" {sans_accents(mot)}" in propre):
                choix[code] = "resume"
                break
    return choix


CONSIGNE_AIGUILLAGE = """Tu aides un coach sportif à choisir les parties de son dossier à relire \
avant de répondre à un message. Voici les parties, avec leur code :

{liste}

Pour chaque partie utile au message, dis si le coach a besoin :
- du résumé (« resume ») : les règles et les chiffres essentiels suffisent ;
- du complet (« complet ») : la question demande du détail (un programme, une liste \
d'exercices, un plan, un calcul précis, une conduite à tenir pour une douleur).

Ne choisis que ce qui sert vraiment, souvent une ou deux parties, parfois aucune. \
Réponds sur une seule ligne, sans rien d'autre, au format code:detail séparés par des \
virgules. Exemple : course:resume, sante:complet. Si rien n'est utile, réponds : aucun"""


def _liste_des_paquets() -> str:
    return "\n".join(f"- {code} : {p.get('titre', code)}"
                     for code, p in dossier.paquets().items())


def lire_la_reponse(texte: str) -> dict[str, str]:
    choix = {}
    for code, detail in re.findall(r"([a-z_]+)\s*:\s*(resume|résumé|complet)",
                                   sans_accents(texte or "")):
        detail = "resume" if detail.startswith("r") else "complet"
        if code in dossier.paquets():
            choix[code] = detail
    return choix


def par_haiku(texte: str, avant: str | None = None) -> tuple[dict[str, str], modele.Tour]:
    """DOS-4 : le petit modèle lit le message (et la question du coach à laquelle il
    répond, s'il y en a une) et choisit. Lève ModeleInjoignable s'il ne répond pas."""
    conf = configuration()
    if not conf.coach_modele_aiguillage:
        raise modele.ModeleInjoignable("Aucun modèle d'aiguillage n'est réglé")
    message = ""
    if avant:
        message += f"Le dernier message du coach :\n{avant[:600]}\n\n"
    message += f"Le message de l'utilisateur :\n{texte[:2000]}"
    tour = modele.ecrire(CONSIGNE_AIGUILLAGE.format(liste=_liste_des_paquets()), message,
                         conf.coach_modele_aiguillage, 60, DELAI_AIGUILLAGE)
    return lire_la_reponse(tour.texte), tour


def disciplines_en_jeu(id_utilisateur: int, id_occurrence: int | None) -> set[str]:
    """Les disciplines des objectifs actifs, et celle de la séance dont on parle."""
    en_jeu = set()
    for o in lister(
            """SELECT o.type, o.pilier, e.discipline
                 FROM objectif o LEFT JOIN exercice e ON e.id_exercice = o.id_exercice
                WHERE o.id_utilisateur = %(u)s AND o.statut = 'actif'""",
            {"u": id_utilisateur}):
        if o["type"] == "course" or o["pilier"] == "endurance":
            en_jeu.add("course")
        if o["pilier"] in ("force", "physique"):
            en_jeu.add("musculation")
        if o.get("discipline"):
            en_jeu.add(o["discipline"])
    if id_occurrence:
        ligne = un_seul("SELECT discipline FROM seance WHERE id_occurrence = %(o)s",
                        {"o": id_occurrence})
        if ligne and ligne["discipline"]:
            en_jeu.add(ligne["discipline"])
    return en_jeu


def choisir(id_utilisateur: int, moment: str, texte: str | None = None,
            id_occurrence: int | None = None, avant: str | None = None) -> Aiguillage:
    reglage = dossier.reglage_des_paquets()
    resultat = Aiguillage()

    for code, detail in (reglage.get("moments", {}).get(moment) or {}).items():
        resultat.ajouter(code, detail)

    detail_discipline = reglage.get("detail_discipline", {}).get(moment)
    if detail_discipline:
        correspondance = reglage.get("disciplines", {})
        for discipline in sorted(disciplines_en_jeu(id_utilisateur, id_occurrence)):
            if discipline in correspondance:
                resultat.ajouter(correspondance[discipline], detail_discipline)

    if texte and texte.strip():
        try:
            choix, tour = par_haiku(texte, avant)
            resultat.par = "haiku"
            resultat.tokens_entree = tour.tokens_entree
            resultat.tokens_sortie = tour.tokens_sortie
        except modele.ModeleInjoignable as erreur:
            LOG.info("Aiguillage par mots-clés : %s", erreur)
            choix = par_mots_cles(texte)
            resultat.par = "mots"
        for code, detail in choix.items():
            resultat.ajouter(code, detail)
    return resultat
