"""La mémoire du coach, en quatre étages                       (MEM-1 à MEM-9)

Plus on remonte loin, moins il y a de détail, mais le fil reste :

    globale        tout ce qui précède les trois derniers mois      4 000 car.
    trois mois     les résumés des trois derniers mois finis    3 x 1 500 car.
    mois           le mois en cours, nourri par les semaines finies 3 000 car.
    semaine        la semaine en cours, tenue par le coach          3 000 car.

puis, dans l'appel, les dix derniers échanges mot pour mot.

Le coach écrit la semaine (et la globale, pour un fait durable). Le reste se
fait seul, la nuit, par résumé (`rouler`) :

    une semaine finie   est versée dans le mois de son dimanche
    un mois fini        est résumé en 1 500 caractères et archivé
    une archive qui sort des trois derniers mois est versée dans la globale

Chaque étape regarde l'état de la base, pas l'heure : une nuit manquée se
rattrape la suivante, et rien n'est versé deux fois. Les consignes de résumé
sont dans `coach/memoire.md`, à côté du dossier : on les ajuste sans toucher
au code.
"""

import logging
from datetime import date, timedelta
from functools import lru_cache

from api.base import executer, lister, un_seul
from api.coach import dossier, modele
from api.coach.clair import aujourd_hui, clair, jour_en_clair, lundi_de
from api.config import configuration

LOG = logging.getLogger(__name__)

MOIS = ("janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août",
        "septembre", "octobre", "novembre", "décembre")

# MEM-6 : jusqu'où remonter la première fois, pour ne pas résumer des mois
# d'historique en une nuit.
MOIS_DE_REPRISE = 3

DELAI_RESUME = 180.0
TOKENS_RESUME = 2500


class ResumeImpossible(Exception):
    """Un résumé qui n'a pas pu se faire : la nuit suivante réessaiera."""


def mois_en_clair(premier: date) -> str:
    return f"{MOIS[premier.month - 1]} {premier.year}"


def premier_du_mois(jour: date) -> date:
    return jour.replace(day=1)


def mois_precedent(premier: date, n: int = 1) -> date:
    annee, mois = premier.year, premier.month - n
    while mois < 1:
        mois += 12
        annee -= 1
    return date(annee, mois, 1)


# ---------------------------------------------------------------------------
# Lire
# ---------------------------------------------------------------------------

def en_vigueur(id_utilisateur: int, niveau: str, periode: date | None = None) -> dict | None:
    return un_seul(
        """SELECT id_memoire, niveau, periode, texte, auteur, couvre_jusqu_au, quand,
                  longueur, limite
             FROM v_memoire_coach
            WHERE id_utilisateur = %(u)s AND niveau = %(n)s
              AND periode IS NOT DISTINCT FROM %(p)s::DATE""",
        {"u": id_utilisateur, "n": niveau, "p": periode})


def etat(id_utilisateur: int) -> dict:
    """Ce que le coach a en mémoire aujourd'hui, étage par étage."""
    jour = aujourd_hui()
    lundi = lundi_de(jour)
    premier = premier_du_mois(jour)
    archives = lister(
        """SELECT id_memoire, periode, texte, longueur, limite, quand
             FROM v_memoire_coach
            WHERE id_utilisateur = %(u)s AND niveau = 'archive_mois' AND periode < %(p)s
            ORDER BY periode DESC LIMIT 3""", {"u": id_utilisateur, "p": premier})
    # Une semaine finie pas encore versée (une nuit ratée) reste visible.
    en_attente = lister(
        """SELECT s.id_memoire, s.periode, s.texte, s.longueur, s.limite
             FROM v_memoire_coach s
            WHERE s.id_utilisateur = %(u)s AND s.niveau = 'semaine' AND s.periode < %(l)s
              AND btrim(s.texte) <> ''
              AND NOT EXISTS (
                  SELECT 1 FROM v_memoire_coach m
                   WHERE m.id_utilisateur = s.id_utilisateur AND m.niveau = 'mois'
                     AND m.couvre_jusqu_au >= s.periode)
            ORDER BY s.periode""", {"u": id_utilisateur, "l": lundi})
    return {
        "globale": en_vigueur(id_utilisateur, "globale"),
        "trois_mois": list(reversed(archives)),
        "mois": en_vigueur(id_utilisateur, "mois", premier),
        "semaine": en_vigueur(id_utilisateur, "semaine", lundi),
        "semaines_en_attente": en_attente,
        "mois_courant": premier,
        "lundi": lundi,
    }


def _taille(ligne: dict | None, niveau: str) -> str:
    longueur = (ligne or {}).get("longueur") or 0
    limite = (ligne or {}).get("limite") or {
        "globale": 4000, "mois": 3000, "semaine": 3000, "archive_mois": 1500}[niveau]
    alerte = " TROP LONGUE : résume-la à ta prochaine écriture" if longueur > limite else ""
    return f"({longueur}/{limite} caractères{alerte})"


def texte(id_utilisateur: int) -> str:
    """MEM-1 : la mémoire telle qu'elle entre dans la consigne, du plus ancien au
    plus récent."""
    e = etat(id_utilisateur)
    morceaux = [
        "# Ta mémoire",
        "Du plus ancien et plus résumé au plus récent et plus précis. Les derniers "
        "échanges, mot pour mot, viennent après. Ce qui n'est plus ici se retrouve avec "
        "`lire_echanges`.",
    ]

    g = e["globale"]
    morceaux.append(f"## Mémoire globale : ce qui précède les trois derniers mois "
                    f"{_taille(g, 'globale')}")
    morceaux.append((g or {}).get("texte") or "Vide pour l'instant.")

    morceaux.append("## Les trois derniers mois")
    if not e["trois_mois"]:
        morceaux.append("Aucun mois fini résumé pour l'instant.")
    for a in e["trois_mois"]:
        morceaux.append(f"### {mois_en_clair(a['periode']).capitalize()}")
        morceaux.append(a["texte"] or "(rien)")

    m = e["mois"]
    morceaux.append(f"## Le mois en cours : {mois_en_clair(e['mois_courant'])} "
                    f"{_taille(m, 'mois')}")
    morceaux.append((m or {}).get("texte") or "Rien encore : les semaines finies du mois "
                    "y seront versées.")

    for s in e["semaines_en_attente"]:
        morceaux.append(f"## La semaine du {clair(s['periode'])}, finie mais pas encore "
                        "versée dans le mois")
        morceaux.append(s["texte"])

    s = e["semaine"]
    morceaux.append(f"## La semaine en cours, depuis le {jour_en_clair(e['lundi'])} "
                    f"{_taille(s, 'semaine')}")
    morceaux.append((s or {}).get("texte") or "Rien encore cette semaine.")
    return "\n\n".join(morceaux)


def versions(id_utilisateur: int, niveau: str, periode: date | None = None,
             limite: int = 10) -> list[dict]:
    return lister(
        """SELECT id_memoire, niveau, periode, auteur, quand, char_length(texte) AS longueur,
                  left(texte, 200) AS debut
             FROM memoire_coach
            WHERE id_utilisateur = %(u)s AND niveau = %(n)s
              AND periode IS NOT DISTINCT FROM %(p)s::DATE
            ORDER BY id_memoire DESC LIMIT %(l)s""",
        {"u": id_utilisateur, "n": niveau, "p": periode, "l": limite})


def ecrire(id_utilisateur: int, niveau: str, texte_nouveau: str, auteur: str,
           periode: date | None = None, couvre: date | None = None,
           tour: modele.Tour | None = None, modele_nom: str | None = None) -> int:
    ligne = executer(
        """SELECT ecrire_memoire(%(u)s, %(n)s, %(t)s, %(a)s, %(p)s, %(c)s, %(m)s,
                                 %(e)s, %(s)s) AS id""",
        {"u": id_utilisateur, "n": niveau, "t": texte_nouveau, "a": auteur, "p": periode,
         "c": couvre, "m": modele_nom,
         "e": tour.tokens_entree if tour else None,
         "s": tour.tokens_sortie if tour else None})
    return ligne["id"]


# ---------------------------------------------------------------------------
# Résumer
# ---------------------------------------------------------------------------

@lru_cache
def consigne_de_resume() -> str:
    fichier = dossier.racine().parent / "memoire.md"
    return fichier.read_text(encoding="utf-8").strip() if fichier.exists() else ""


def _modele_de_resume() -> str:
    conf = configuration()
    return conf.coach_modele_memoire or conf.coach_modele


def resumer(etape: str, materiau: str, limite: int) -> tuple[str, modele.Tour]:
    """MEM-7 : un résumé, sous la limite. Un seul nouvel essai s'il déborde."""
    systeme = consigne_de_resume() + "\n\n# Ce que tu fais maintenant\n\n" + etape + \
        f"\n\nLimite : {limite} caractères, espaces compris. Rends le texte seul."
    nom = _modele_de_resume()
    tour = modele.ecrire(systeme, materiau, nom, TOKENS_RESUME, DELAI_RESUME)
    texte_rendu = tour.texte.strip()
    if len(texte_rendu) > limite:
        relance = (materiau + "\n\n# Ta première version, trop longue\n\n" + texte_rendu
                   + f"\n\nElle fait {len(texte_rendu)} caractères pour {limite} permis. "
                   "Raccourcis-la sans perdre ce qui est important.")
        second = modele.ecrire(systeme, relance, nom, TOKENS_RESUME, DELAI_RESUME)
        second.tokens_entree += tour.tokens_entree
        second.tokens_sortie += tour.tokens_sortie
        tour, texte_rendu = second, second.texte.strip()
    if not texte_rendu or len(texte_rendu) > limite:
        raise ResumeImpossible(f"résumé vide ou trop long ({len(texte_rendu)}/{limite})")
    return texte_rendu, tour


def echanges_de(id_utilisateur: int, du: date, au: date) -> str:
    """MEM-8 : les échanges d'une période, du plus important au moins important.

    Un échange important passe presque en entier, un échange courant n'est que
    compté : c'est ce qui fait qu'un résumé oublie un bilan banal, jamais un
    changement d'objectif.
    """
    lignes = lister(
        """SELECT quand, auteur, moment, importance, contenu FROM echange
            WHERE id_utilisateur = %(u)s AND jour_de(quand) BETWEEN %(du)s AND %(au)s
            ORDER BY id_echange""", {"u": id_utilisateur, "du": du, "au": au})
    if not lignes:
        return "Aucun échange sur la période."
    morceaux = []
    courants = 0
    for ligne in lignes:
        if ligne["importance"] <= 1:
            courants += 1
            continue
        coupe = 2500 if ligne["importance"] >= 3 else 900
        qui = {"utilisateur": "Utilisateur", "coach": "Coach",
               "systeme": "Message automatique"}[ligne["auteur"]]
        contenu = ligne["contenu"]
        if len(contenu) > coupe:
            contenu = contenu[:coupe] + " […]"
        morceaux.append(f"[{clair(ligne['quand'])}, {ligne['moment']}, importance "
                        f"{ligne['importance']}] {qui} : {contenu}")
    if courants:
        morceaux.append(f"Et {courants} échange(s) courant(s) (importance 1), non repris : "
                        "bilans sans surprise, questions réglées.")
    return "\n\n".join(morceaux)


def seances_de(id_utilisateur: int, du: date, au: date) -> str:
    lignes = lister(
        """SELECT jour, discipline, type_seance, intensite, duree_minutes, situation,
                  effort, duree_reelle, commentaire, libre
             FROM v_seance_coach
            WHERE id_utilisateur = %(u)s AND jour BETWEEN %(du)s AND %(au)s
            ORDER BY jour, debut""", {"u": id_utilisateur, "du": du, "au": au})
    if not lignes:
        return "Aucune séance."
    morceaux = []
    for s in lignes:
        quoi = s["type_seance"] or s["discipline"] or "séance"
        detail = [s["situation"] or ""]
        if s["effort"] is not None:
            detail.append(f"effort {s['effort']}/10")
        if s["duree_reelle"]:
            detail.append(f"{s['duree_reelle']} min")
        if s["libre"]:
            detail.append("libre")
        ligne = f"- {jour_en_clair(s['jour'])} : {quoi} ({', '.join(d for d in detail if d)})"
        if s["commentaire"]:
            ligne += f" : « {s['commentaire'][:200]} »"
        morceaux.append(ligne)
    return "\n".join(morceaux)


ETAPE_SEMAINE = (
    "Une semaine vient de finir. Réécris la mémoire du mois en y intégrant cette "
    "semaine. Le mois doit rester lisible d'un coup d'œil : où en est l'utilisateur, ce "
    "qui a changé, ce qui marche, ce qui inquiète, ce qu'il a demandé. Fusionne avec "
    "ce que le mois disait déjà au lieu d'empiler les semaines.")

ETAPE_MOIS = (
    "Un mois vient de finir. Résume sa mémoire en un texte court, qui rejoindra les "
    "trois derniers mois. Garde les tendances, les décisions, les changements "
    "d'objectif ou de plan, les douleurs et leur évolution, les chiffres clés datés.")

ETAPE_GLOBALE = (
    "Un mois sort des trois derniers mois. Réécris la mémoire globale en y intégrant ce "
    "qu'il apporte de durable. La mémoire globale dit qui est l'utilisateur pour son "
    "coach : ses objectifs dans le temps, ce qui marche ou pas pour lui, ses limites, "
    "ses préférences dites, les grandes étapes. Le détail d'un mois n'y a pas sa place.")


def _verser_les_semaines(id_utilisateur: int, jour: date, fait: list[str]) -> None:
    lundi = lundi_de(jour)
    plancher = lundi_de(mois_precedent(premier_du_mois(jour), MOIS_DE_REPRISE))
    candidates = lister(
        """SELECT DISTINCT lundi FROM (
               SELECT periode AS lundi FROM v_memoire_coach
                WHERE id_utilisateur = %(u)s AND niveau = 'semaine'
               UNION
               SELECT lundi_de(jour_de(quand)) FROM echange WHERE id_utilisateur = %(u)s
           ) x
            WHERE lundi < %(l)s AND lundi >= %(p)s ORDER BY lundi""",
        {"u": id_utilisateur, "l": lundi, "p": plancher})
    for ligne in candidates:
        debut = ligne["lundi"]
        fin = debut + timedelta(days=6)
        mois_cible = premier_du_mois(fin)
        mois = en_vigueur(id_utilisateur, "mois", mois_cible)
        if mois and mois["couvre_jusqu_au"] and mois["couvre_jusqu_au"] >= debut:
            continue
        semaine = en_vigueur(id_utilisateur, "semaine", debut)
        ecrit = ((semaine or {}).get("texte") or "").strip()
        echanges = echanges_de(id_utilisateur, debut, fin)
        seances = seances_de(id_utilisateur, debut, fin)
        avant = ((mois or {}).get("texte") or "").strip()
        materiau = (
            f"# La mémoire du mois de {mois_en_clair(mois_cible)}, jusqu'ici\n\n"
            f"{avant or '(vide : c’est la première semaine versée dans ce mois)'}\n\n"
            f"# La semaine du {jour_en_clair(debut)} au {jour_en_clair(fin)}\n\n"
            f"## Ce que le coach en a retenu au fil des jours\n\n{ecrit or '(rien écrit)'}"
            f"\n\n## Les séances\n\n{seances}\n\n## Les échanges\n\n{echanges}")
        rien = not ecrit and seances == "Aucune séance." and \
            echanges == "Aucun échange sur la période."
        if rien:
            ecrire(id_utilisateur, "mois", avant, "resume", mois_cible, debut)
            continue
        nouveau, tour = resumer(ETAPE_SEMAINE, materiau, 3000)
        ecrire(id_utilisateur, "mois", nouveau, "resume", mois_cible, debut, tour,
               _modele_de_resume())
        fait.append(f"semaine du {debut} versée dans {mois_en_clair(mois_cible)}")


def _archiver_les_mois(id_utilisateur: int, jour: date, fait: list[str]) -> None:
    for mois in lister(
            """SELECT m.periode, m.texte FROM v_memoire_coach m
                WHERE m.id_utilisateur = %(u)s AND m.niveau = 'mois' AND m.periode < %(p)s
                  AND NOT EXISTS (SELECT 1 FROM memoire_coach a
                                   WHERE a.id_utilisateur = m.id_utilisateur
                                     AND a.niveau = 'archive_mois'
                                     AND a.periode = m.periode)
                ORDER BY m.periode""", {"u": id_utilisateur, "p": premier_du_mois(jour)}):
        texte_mois = (mois["texte"] or "").strip()
        if len(texte_mois) <= 1500:
            # Déjà assez court : rien à résumer, il est archivé tel quel.
            ecrire(id_utilisateur, "archive_mois", texte_mois or "(mois sans rien de notable)",
                   "resume", mois["periode"])
        else:
            court, tour = resumer(
                ETAPE_MOIS, f"# La mémoire de {mois_en_clair(mois['periode'])}\n\n"
                            f"{texte_mois}", 1500)
            ecrire(id_utilisateur, "archive_mois", court, "resume", mois["periode"], None,
                   tour, _modele_de_resume())
        fait.append(f"{mois_en_clair(mois['periode'])} archivé")


def _verser_dans_la_globale(id_utilisateur: int, jour: date, fait: list[str]) -> None:
    globale = en_vigueur(id_utilisateur, "globale")
    deja = (globale or {}).get("couvre_jusqu_au")
    recentes = [a["periode"] for a in lister(
        """SELECT periode FROM v_memoire_coach
            WHERE id_utilisateur = %(u)s AND niveau = 'archive_mois' AND periode < %(p)s
            ORDER BY periode DESC LIMIT 3""",
        {"u": id_utilisateur, "p": premier_du_mois(jour)})]
    sortantes = lister(
        """SELECT periode, texte FROM v_memoire_coach
            WHERE id_utilisateur = %(u)s AND niveau = 'archive_mois' AND periode < %(p)s
              AND (%(d)s::DATE IS NULL OR periode > %(d)s::DATE)
            ORDER BY periode""",
        {"u": id_utilisateur, "p": premier_du_mois(jour), "d": deja})
    for archive in sortantes:
        if archive["periode"] in recentes:
            continue
        avant = ((globale or {}).get("texte") or "").strip()
        nouveau, tour = resumer(
            ETAPE_GLOBALE,
            f"# La mémoire globale jusqu'ici\n\n{avant or '(vide)'}\n\n"
            f"# Le mois qui sort : {mois_en_clair(archive['periode'])}\n\n{archive['texte']}",
            4000)
        ecrire(id_utilisateur, "globale", nouveau, "resume", None, archive["periode"], tour,
               _modele_de_resume())
        globale = en_vigueur(id_utilisateur, "globale")
        fait.append(f"{mois_en_clair(archive['periode'])} versé dans la mémoire globale")


def rouler(id_utilisateur: int, jour: date | None = None) -> list[str]:
    """MEM-6 : la nuit, chaque étage absorbe ce qui est fini en dessous de lui.

    Une étape qui échoue arrête la nuit pour ce compte : la suivante réessaiera
    exactement là, puisque tout se lit dans la base.
    """
    jour = jour or aujourd_hui()
    fait: list[str] = []
    try:
        _verser_les_semaines(id_utilisateur, jour, fait)
        _archiver_les_mois(id_utilisateur, jour, fait)
        _verser_dans_la_globale(id_utilisateur, jour, fait)
    except (ResumeImpossible, modele.ModeleInjoignable) as erreur:
        LOG.warning("Mémoire du coach : roulement interrompu (%s)", erreur)
        fait.append(f"interrompu : {erreur}")
    return fait


def oublier_le_cache() -> None:
    consigne_de_resume.cache_clear()
