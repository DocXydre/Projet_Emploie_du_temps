"""Les lectures faites d'office, avant le premier passage au modèle     (COA-28)

Pour chaque moment, on sait ce que le modèle va lire : la semaine, la santé, la
forme, l'emploi du temps. Les lui demander coûtait un passage entier, et chaque
passage relit toute la consigne. Elles sont donc faites ici, avec les mêmes
outils, et jointes au premier message. Ses outils de lecture restent là pour une
autre période ou une séance précise.

Une lecture qui échoue est sautée : le modèle peut toujours la refaire.
"""

import json
import logging
from datetime import date, timedelta

from api.base import lister
from api.coach import aiguillage, contexte, outils
from api.coach.clair import aujourd_hui, clair, jour_en_clair, lundi_de

LOG = logging.getLogger(__name__)


def _json(valeur) -> str:
    if isinstance(valeur, str):
        return valeur
    return json.dumps(clair(valeur), ensure_ascii=False, separators=(",", ":"))


def planning_en_clair(id_utilisateur: int, jours: int, depuis=None) -> str:
    """L'emploi du temps en lignes courtes : un jour par ligne, ses créneaux pris."""
    du = depuis or aujourd_hui()
    au = du + timedelta(days=jours - 1)
    rendu = outils.lire_planning(id_utilisateur, {"du": du.isoformat(), "au": au.isoformat()})
    lignes = []
    for j in rendu["jours"]:
        d = date.fromisoformat(j["jour"])
        pris = " ; ".join(j["pris"]) if j["pris"] else "rien de prévu"
        lignes.append(f"{jour_en_clair(d)} : charge {j['charge_de_la_journee']}, "
                      f"{j['heures_de_cours_et_travail']} h de cours et travail. {pris}")
    for a in rendu["absences"]:
        lignes.append(f"Absence {a['periode']} ({a['lieu'] or 'sans lieu'})")
    lignes.append(rendu["note"])
    return "\n".join(lignes)


def _seances_du_jour(id_utilisateur: int) -> str | None:
    """Le détail des séances du jour (prévu, saisi, montre) : ce que la synthèse juge."""
    ids = [x["id_occurrence"] for x in lister(
        """SELECT id_occurrence FROM v_seance_coach
            WHERE id_utilisateur = %(u)s AND jour = %(j)s
            ORDER BY debut NULLS LAST, id_occurrence""",
        {"u": id_utilisateur, "j": aujourd_hui()})]
    if not ids:
        return "Aucune séance aujourd'hui."
    return "\n".join(_json(outils.lire_seance(id_utilisateur, {"id_occurrence": i}))
                     for i in ids)


def _musculation_en_jeu(id_utilisateur: int, moment: str, id_occurrence: int | None) -> bool:
    """La fiche complète d'une limitation sert quand une séance de musculation se
    construit ou se commente (EXO-10)."""
    if moment in ("plan", "revision"):
        return True
    if "musculation" in aiguillage.disciplines_en_jeu(id_utilisateur, id_occurrence):
        return True
    if moment == "synthese":
        return bool(lister(
            """SELECT 1 FROM v_seance_coach WHERE id_utilisateur = %(u)s AND jour = %(j)s
                 AND discipline = 'musculation' LIMIT 1""",
            {"u": id_utilisateur, "j": aujourd_hui()}))
    return False


def _lectures(id_utilisateur: int, moment: str, id_occurrence: int | None) -> list:
    """Ce que chaque moment lit d'office : (titre, fonction qui rend le texte)."""
    u = id_utilisateur
    today = aujourd_hui()
    semaine = ("La semaine en cours (lire_semaine)", lambda: outils.lire_semaine(u, {}))
    forme = ("Charge et forme (lire_forme)", lambda: outils.lire_forme(u, {}))
    mesures = ("Mesures et fenêtres (lire_mesures)", lambda: outils.lire_mesures(u, {}))

    def sante(jours: int):
        return (f"Santé et séances de la montre, {jours} derniers jours (lire_sante)",
                lambda: outils.lire_sante(u, {"du": (today - timedelta(days=jours - 1))
                                              .isoformat()}))

    def planning(jours: int, depuis=None):
        return (f"Emploi du temps sur {jours} jours (lire_planning)",
                lambda: planning_en_clair(u, jours, depuis))

    catalogue = ("Catalogue des exercices permis (lire_catalogue)",
                 lambda: outils.lire_catalogue(u, {}))
    # SAN-17 : les dernières courses, résumées, pour régler les suivantes.
    courses = ("Les dernières courses, étape par étape (lire_courses)",
               lambda: outils.lire_courses(u, {"nombre": 6}))

    if moment == "faisabilite":
        return [sante(28), courses, mesures, forme, planning(28)]
    if moment == "plan":
        return [semaine, sante(28), courses, forme, mesures, planning(28), catalogue]
    if moment == "revision":
        suivante = lundi_de(today) + timedelta(days=7)
        return [semaine,
                ("Séances du jour en détail (lire_seance)", lambda: _seances_du_jour(u)),
                ("La semaine suivante (lire_semaine)",
                 lambda: outils.lire_semaine(u, {"lundi": suivante.isoformat()})),
                sante(14), courses, forme, mesures, planning(21, today + timedelta(days=1)),
                catalogue]
    if moment == "synthese":
        return [semaine,
                ("Séances du jour en détail (lire_seance)", lambda: _seances_du_jour(u)),
                sante(7), forme, mesures, planning(2, today + timedelta(days=1))]
    if moment == "bilan" and id_occurrence:
        return [("La séance close (lire_seance)",
                 lambda: outils.lire_seance(u, {"id_occurrence": id_occurrence})),
                semaine, forme]
    if moment == "signalement":
        return [semaine, sante(7), forme]
    if moment == "changement":
        lectures = [semaine, forme, planning(14)]
        if id_occurrence:
            lectures.insert(0, ("La séance dont on parle (lire_seance)",
                                lambda: outils.lire_seance(u, {"id_occurrence": id_occurrence})))
        return lectures
    return []


def texte(id_utilisateur: int, moment: str, id_occurrence: int | None = None) -> str:
    """Le bloc joint au premier message, ou une chaîne vide (chat)."""
    morceaux = []
    lectures = _lectures(id_utilisateur, moment, id_occurrence)
    if moment != "chat" and _musculation_en_jeu(id_utilisateur, moment, id_occurrence):
        lectures.append(("Fiches complètes des limitations",
                         lambda: contexte.fiches_completes(id_utilisateur) or ""))
    for titre, lire in lectures:
        try:
            lu = lire()
            if lu:
                morceaux.append(f"## {titre}\n{_json(lu)}")
        except Exception as erreur:  # noqa: BLE001 - une lecture manquée se refait par outil
            LOG.warning("Lecture d'office « %s » sautée : %s", titre, erreur)
    if moment in ("synthese", "revision"):
        # MTO-5 : la veille, la prévision des séances dehors de demain.
        try:
            from api import meteo
            lu = meteo.texte_du_lendemain(id_utilisateur)
            if lu:
                morceaux.append(lu)
        except Exception as erreur:  # noqa: BLE001 - la météo manquée se lit par outil
            LOG.warning("Météo du lendemain sautée : %s", erreur)
    if not morceaux:
        return ""
    return ("# Données lues pour toi à l'ouverture de l'appel\n"
            "Elles sont à jour : ne les relis pas avec tes outils. Tes outils de lecture "
            "servent pour une autre période, une autre semaine ou une séance précise.\n\n"
            + "\n\n".join(morceaux))
