"""Les outils du coach : la liste fermée de ce que le modèle peut demander
                                                              (COA-4, COA-5)

Chaque outil lit une vue ou appelle une fonction SQL, pour l'utilisateur de
l'appel et lui seul : le modèle ne choisit jamais de qui il parle. Un outil
d'écriture appelle une fonction SQL et rien d'autre. Un refus de la base est un
résultat comme un autre : le modèle lit le motif et corrige.

Chaque appel d'outil ouvre et valide sa propre transaction (COA-23) : aucune
connexion à la base n'est tenue pendant que le modèle réfléchit.
"""

import json
from collections.abc import Callable
from dataclasses import dataclass
from datetime import date, timedelta

import psycopg
from psycopg.types.json import Jsonb

from api.base import executer, lister, un_seul
from api.coach import dossier, lecture_courses
from api.coach.clair import aujourd_hui, clair, lundi_de, sans_vides
from api.config import configuration
from api.erreurs import message_lisible, refus_coach

# ---------------------------------------------------------------------------
# Les moments, et les familles d'outils que chacun ouvre (COA-5, section 9.2)
# ---------------------------------------------------------------------------

MOMENTS = ("faisabilite", "plan", "revision", "synthese", "bilan", "signalement", "chat",
           "changement")

FAMILLES_DU_MOMENT = {
    "faisabilite": {"lecture", "avis", "memoire"},
    "plan":        {"lecture", "trame", "seances", "fenetre", "memoire"},
    "revision":    {"lecture", "trame", "seances", "fenetre", "memoire", "avis_libre"},
    "synthese":    {"lecture", "seances", "fenetre", "memoire", "avis_libre", "mesure"},
    "bilan":       {"lecture", "seances", "memoire", "avis_libre", "mesure"},
    "signalement": {"lecture", "seances", "memoire", "avis_libre", "mesure", "demandes"},
    # COA-32 : une demande de changement. HAL propose ou dépose un ajustement ;
    # rien ne s'applique sans le bouton de l'utilisateur.
    "changement":  {"lecture", "seances", "memoire", "demandes"},
    # Dans le chat, le coach lit et tient sa mémoire : il ne propose aucune séance.
    # S'il lit un signalement dans le texte, il le requalifie (COA-25). Il fait les
    # gestes de l'onglet Sport qu'on lui demande (ACT-1) ; la maison est au HAL du
    # foyer (AIG).
    "chat":        {"lecture", "memoire", "requalification", "mesure", "gestes_sport"},
}

# PAU-2 : en pause, ces familles sont fermées pour tous les moments.
FERMEES_EN_PAUSE = {"trame", "seances"}

DISCIPLINES = ["musculation", "course", "cardio"]
INTENSITES = ["legere", "moderee", "dure"]
GROUPES = ["pectoraux", "dos", "epaules", "biceps", "triceps", "avant_bras", "abdominaux",
           "lombaires", "fessiers", "quadriceps", "ischios", "adducteurs", "mollets"]
ROLES = ["calibrage", "charge", "allegee", "test", "affutage", "reprise"]
TYPES_MESURE = ["poids", "tour_taille", "tour_bras", "tour_avant_bras", "tour_cuisse",
                "tour_poitrine", "test_course", "test_force"]


class RefusOutil(Exception):
    """Un refus à rendre au modèle : un code stable et un motif lisible."""

    def __init__(self, code: str, motif: str):
        super().__init__(motif)
        self.code = code
        self.motif = motif


@dataclass(frozen=True)
class Outil:
    nom: str
    famille: str
    description: str
    schema: dict
    fonction: Callable[[int, dict], object]
    # Permis mais pas déclaré au modèle : un ancien nom qui reste accepté, sans
    # que son schéma parte une deuxième fois (proposer_seances le remplace).
    cache: bool = False

    def declaration(self) -> dict:
        return {"name": self.nom, "description": self.description,
                "input_schema": self.schema}


def _objet(proprietes: dict, requis: list[str] | None = None) -> dict:
    return {"type": "object", "properties": proprietes, "required": requis or [],
            "additionalProperties": False}


def _jour(valeur, nom: str = "jour") -> date:
    try:
        return date.fromisoformat(str(valeur))
    except (TypeError, ValueError):
        raise RefusOutil("requete_invalide",
                         f"« {nom} » doit être une date au format AAAA-MM-JJ") from None


# ---------------------------------------------------------------------------
# Lecture
# ---------------------------------------------------------------------------

def lire_chapitre(u: int, a: dict) -> object:
    texte = dossier.chapitre(str(a.get("numero", "")))
    if texte is None:
        raise RefusOutil("introuvable",
                         "Ce chapitre n'existe pas. Les numéros sont dans le sommaire.")
    return texte


def lire_echanges(u: int, a: dict) -> object:
    """MEM-8 : chercher dans tout l'historique, au-delà des derniers échanges."""
    limite = min(int(a.get("limite") or 10), 20)
    cherche = (a.get("cherche") or "").strip()
    du = _jour(a["du"], "du") if a.get("du") else None
    au = _jour(a["au"], "au") if a.get("au") else None
    lignes = lister(
        """SELECT id_echange, quand, auteur, moment, importance,
                  CASE WHEN char_length(contenu) > 1500
                       THEN left(contenu, 1500) || ' […]' ELSE contenu END AS contenu
             FROM echange
            WHERE id_utilisateur = %(u)s
              AND importance >= %(i)s
              -- Les derniers échanges sont déjà sous ses yeux : pas deux fois.
              AND id_echange NOT IN (SELECT r.id_echange FROM echange r
                                      WHERE r.id_utilisateur = %(u)s
                                      ORDER BY r.id_echange DESC LIMIT %(n)s)
              AND (%(du)s::DATE IS NULL OR jour_de(quand) >= %(du)s::DATE)
              AND (%(au)s::DATE IS NULL OR jour_de(quand) <= %(au)s::DATE)
              AND (%(c)s = '' OR contenu ILIKE '%%' || %(c)s || '%%')
            ORDER BY id_echange DESC LIMIT %(l)s""",
        {"u": u, "i": int(a.get("importance_min") or 1), "du": du, "au": au,
         "c": cherche, "l": limite, "n": configuration().coach_echanges_rendus})
    if not lignes:
        return {"echanges": [], "note": "Aucun échange plus ancien que les derniers échanges "
                                        "que tu as déjà ne correspond."}
    return {"echanges": list(reversed(lignes))}


def lire_planning(u: int, a: dict) -> object:
    du = _jour(a.get("du"), "du")
    au = _jour(a.get("au"), "au")
    if au < du or (au - du).days > 34:
        raise RefusOutil("requete_invalide", "La période va de 1 à 35 jours")
    charges = lister(
        """SELECT jour, heures, premier_debut, derniere_fin, niveau
             FROM v_charge_journee
            WHERE id_utilisateur = %(u)s AND jour BETWEEN %(du)s AND %(au)s
            ORDER BY jour""", {"u": u, "du": du, "au": au})
    creneaux = lister(
        """SELECT jour_de(p.debut) AS jour, p.debut, p.fin, p.categorie, p.libelle,
                  p.journee_entiere
             FROM v_planning p
            WHERE p.id_utilisateur = %(u)s AND p.nature IN ('occupation', 'tache')
              AND NOT p.journee_entiere
              AND p.debut < debut_jour(%(au)s::DATE + 1) AND p.fin > debut_jour(%(du)s::DATE)
            ORDER BY p.debut""", {"u": u, "du": du, "au": au})
    absences = lister(
        """SELECT a.periode, a.lieu FROM absence a
            WHERE a.id_utilisateur = %(u)s
              AND a.periode && tstzrange(debut_jour(%(du)s::DATE),
                                         debut_jour(%(au)s::DATE + 1), '[)')
            ORDER BY lower(a.periode)""", {"u": u, "du": du, "au": au})
    par_jour: dict[date, dict] = {}
    for c in charges:
        par_jour[c["jour"]] = {
            "jour": c["jour"].isoformat(),
            "charge_de_la_journee": c["niveau"],
            "heures_de_cours_et_travail": clair(c["heures"]),
            "pris": []}
    for c in creneaux:
        if c["jour"] in par_jour:
            heures = f"{clair(c['debut'])[11:]}-{clair(c['fin'])[11:]}"
            par_jour[c["jour"]]["pris"].append(
                f"{heures} {c['libelle']} ({c['categorie']})")
    return {"jours": list(par_jour.values()),
            "absences": [{"periode": clair(x["periode"]), "lieu": x["lieu"]} for x in absences],
            "note": "Les créneaux « tache » sont du ménage encore mobile : une séance "
                    "passe avant, il se replace autour. Seuls les cours, le travail et ce "
                    "qui est annoncé bloquent vraiment."}


COLONNES_SEANCE = """id_occurrence, jour, debut, lieu, id_lieu, situation, auteur, libre, annoncee,
    discipline, type_seance, intensite, cle, est_test, duree_minutes, groupes, exercices,
    series_saisies, effort, duree_reelle, charge, commentaire, activite_montre, avis_libre,
    motif"""


def lire_semaine(u: int, a: dict) -> object:
    lundi = lundi_de(_jour(a.get("lundi") or aujourd_hui().isoformat(), "lundi"))
    seances = lister(
        f"""SELECT {COLONNES_SEANCE} FROM v_seance_coach
             WHERE id_utilisateur = %(u)s AND lundi = %(l)s
             ORDER BY jour, debut NULLS LAST, id_occurrence""", {"u": u, "l": lundi})
    semaine = un_seul(
        """SELECT ps.role, ps.intention, ps.validee_le
             FROM plan p JOIN plan_semaine ps ON ps.id_plan = p.id_plan
            WHERE p.id_utilisateur = %(u)s AND p.statut = 'en_cours' AND ps.lundi = %(l)s""",
        {"u": u, "l": lundi})
    ajustements = lister(
        """SELECT a.id_ajustement, a.id_occurrence, a.nature, a.motif, a.statut, a.contenu
             FROM ajustement a JOIN v_seance_coach s ON s.id_occurrence = a.id_occurrence
            WHERE s.id_utilisateur = %(u)s AND s.lundi = %(l)s
            ORDER BY a.id_ajustement""", {"u": u, "l": lundi})
    return {"lundi": lundi.isoformat(),
            "semaine_du_plan": clair(semaine) if semaine else "hors du plan en cours",
            "seances": [sans_vides(clair(s)) for s in seances],
            "ajustements": [sans_vides(clair(x)) for x in ajustements]}


def detail_seance(u: int, id_occurrence: int) -> dict | None:
    """Une séance : prévu, alternatives permises, saisi, bilan, montre."""
    seance = un_seul(
        f"""SELECT {COLONNES_SEANCE}, consigne, etat, esquisse, statut_occurrence,
                   id_occurrence_remplacee
              FROM v_seance_coach
             WHERE id_utilisateur = %(u)s AND id_occurrence = %(o)s""",
        {"u": u, "o": id_occurrence})
    if seance is None:
        return None
    prevus = lister(
        """SELECT se.id_seance_exercice, se.rang, e.id_exercice, e.code, e.libelle,
                  e.groupe_principal, e.materiel, e.unilateral, e.mesure,
                  se.series, se.repetitions_min, se.repetitions_max, se.charge_kg,
                  se.duree_secondes, se.distance_m, se.repos_secondes,
                  se.marge_repetitions, se.cible, se.consigne,
                  -- EXO-7 : les alternatives excluent ce qui est interdit à ce compte.
                  COALESCE((SELECT jsonb_agg(jsonb_build_object(
                                       'id_exercice', alt.id_exercice, 'code', alt.code,
                                       'libelle', alt.libelle) ORDER BY ea.rang)
                              FROM exercice_alternative ea
                              JOIN exercice alt ON alt.id_exercice = ea.id_alternative
                             WHERE ea.id_exercice = e.id_exercice AND alt.actif
                               AND NOT EXISTS (
                                   SELECT 1 FROM exercice_interdit ei
                                     JOIN limitation l ON l.id_limitation = ei.id_limitation
                                    WHERE l.id_utilisateur = %(u)s AND l.active
                                      AND ei.id_exercice = alt.id_exercice)), '[]')
                      AS alternatives
             FROM seance_exercice se JOIN exercice e ON e.id_exercice = se.id_exercice
            WHERE se.id_occurrence = %(o)s ORDER BY se.rang""",
        {"u": u, "o": id_occurrence})
    series = lister(
        """SELECT ss.id_serie, e.code, e.libelle, ss.numero, ss.charge_kg, ss.repetitions,
                  ss.duree_secondes, ss.distance_m, ss.marge_repetitions, ss.saisie_le,
                  ss.figee, ss.id_seance_exercice, ss.id_exercice,
                  (ss.id_seance_exercice IS NOT NULL
                   AND ss.id_exercice <> (SELECT x.id_exercice FROM seance_exercice x
                                           WHERE x.id_seance_exercice = ss.id_seance_exercice))
                      AS en_remplacement
             FROM serie_saisie ss JOIN exercice e ON e.id_exercice = ss.id_exercice
            WHERE ss.id_occurrence = %(o)s ORDER BY ss.saisie_le, ss.numero""",
        {"o": id_occurrence})
    montre = lister(
        """SELECT a.type, a.periode, a.duree_secondes, a.distance_m, a.denivele_m,
                  a.energie_kcal, a.fc_moyenne, a.fc_max, a.allure_s_km, a.cadence, a.details
             FROM activite_sante a WHERE a.id_occurrence = %(o)s""", {"o": id_occurrence})
    return {"seance": sans_vides(clair(seance)),
            "prevu": [sans_vides(clair(p)) for p in prevus],
            "saisi": [sans_vides(clair(s)) for s in series],
            "montre": [sans_vides(clair(m)) for m in montre]}


def lire_seance(u: int, a: dict) -> object:
    id_occurrence = int(a.get("id_occurrence", 0))
    detail = detail_seance(u, id_occurrence)
    if detail is None:
        raise RefusOutil("introuvable", "Séance introuvable")
    detail["montre"] = [_allure_en_clair(dict(m)) for m in detail["montre"]]
    # SAN-17 : une course de la montre se lit étape par étape. Ses mesures brutes
    # ne partent pas : la lecture en clair les remplace.
    course = lecture_courses.course_de_la_seance(u, id_occurrence)
    if course:
        detail["course_en_detail"] = course
        for montre in detail["montre"]:
            details = montre.get("details") or {}
            for lourd in ("frequence", "kilometres", "zones"):
                details.pop(lourd, None)
    return detail


def lire_courses(u: int, a: dict) -> object:
    """SAN-17 : les dernières courses, chacune lue étape par étape."""
    try:
        du, au = lecture_courses.periode(a)
    except ValueError:
        raise RefusOutil("requete_invalide", "« du » et « au » au format AAAA-MM-JJ") from None
    if au < du or (au - du).days > 89:
        raise RefusOutil("requete_invalide", "La période va de 1 à 90 jours")
    nombre = max(1, min(int(a.get("nombre") or 6), 12))
    trouvees = lecture_courses.courses(u, du, au, nombre, bool(a.get("detail")))
    return {"periode": f"{du.isoformat()} au {au.isoformat()}",
            "courses": trouvees or "Aucune course avec les mesures de la montre sur la période.",
            "note": "Lu dans les mesures brutes de la montre. Une étape plus rapide de 10 % "
                    "que la moyenne de la course est une fraction ; un nom donné par la montre "
                    "l'emporte. Les courses sans mesures fines n'y sont pas : lire_sante les "
                    "donne en une ligne."}


def _plages(jours: list[date]) -> list[str]:
    """Des jours qui se suivent, regroupés : « 2026-10-10 au 2026-10-11 »."""
    plages: list[list[date]] = []
    for jour in sorted(jours):
        if plages and (jour - plages[-1][-1]).days == 1:
            plages[-1].append(jour)
        else:
            plages.append([jour])
    return [p[0].isoformat() if len(p) == 1 else f"{p[0].isoformat()} au {p[-1].isoformat()}"
            for p in plages]


def _moyennes(jours: list[dict]) -> dict:
    rendu = {}
    for cle, nom in (("pas", "pas"), ("fc_repos", "fc_repos"), ("vfc_ms", "vfc_ms"),
                     ("sommeil_minutes", "sommeil_minutes")):
        valeurs = [float(j[cle]) for j in jours if j.get(cle) is not None]
        if valeurs:
            rendu[nom] = round(sum(valeurs) / len(valeurs), 1 if cle == "vfc_ms" else None)
    rendu["jours_avec_donnees"] = len(jours)
    return rendu


def ligne_activite(x: dict) -> str:
    """Une séance de la montre en une ligne : date, sport, distance, durée, allure, FC."""
    morceaux = [clair(x["debut"]), x.get("discipline") or x.get("type") or "activité"]
    if x.get("distance_m"):
        morceaux.append(f"{float(x['distance_m']) / 1000:.1f} km".replace(".", ","))
    duree = x.get("duree_secondes")
    if duree:
        morceaux.append(f"{duree // 3600} h {duree % 3600 // 60:02d}" if duree >= 3600
                        else f"{duree // 60} min {duree % 60:02d} s")
    if x.get("allure_s_km"):
        morceaux.append(f"{x['allure_s_km'] // 60}:{x['allure_s_km'] % 60:02d} /km")
    if x.get("denivele_m"):
        morceaux.append(f"D+ {int(x['denivele_m'])} m")
    if x.get("fc_moyenne"):
        morceaux.append(f"FC {x['fc_moyenne']}" + (f"/{x['fc_max']}" if x.get("fc_max") else ""))
    morceaux.append(f"séance {x['id_occurrence']}" if x.get("id_occurrence")
                    else "non rattachée")
    return " | ".join(str(m) for m in morceaux)


def lire_sante(u: int, a: dict) -> object:
    au = _jour(a.get("au") or aujourd_hui().isoformat(), "au")
    du = _jour(a.get("du") or (au - timedelta(days=27)).isoformat(), "du")
    if au < du or (au - du).days > 60:
        raise RefusOutil("requete_invalide", "La période va de 1 à 61 jours")
    jours = lister(
        """SELECT jour, pas, fc_repos, vfc_ms, sommeil_minutes
             FROM sante_jour WHERE id_utilisateur = %(u)s AND jour BETWEEN %(du)s AND %(au)s
            ORDER BY jour""", {"u": u, "du": du, "au": au})
    activites = lister(
        """SELECT a.type, a.discipline, lower(a.periode) AS debut, a.duree_secondes,
                  a.distance_m, a.denivele_m, a.fc_moyenne, a.fc_max, a.allure_s_km,
                  a.id_occurrence
             FROM activite_sante a
            WHERE a.id_utilisateur = %(u)s AND a.doublon_de IS NULL
              AND jour_de(lower(a.periode)) BETWEEN %(du)s AND %(au)s
            ORDER BY lower(a.periode)""", {"u": u, "du": du, "au": au})
    fraicheur = un_seul("SELECT dernier_envoi, dernier_jour FROM v_sante_fraicheur "
                        "WHERE id_utilisateur = %(u)s", {"u": u}) or {}
    presents = {j["jour"] for j in jours}
    rendu = {
        # SAN-5, SAN-6 : un jour sans ligne est un jour sans données, pas un zéro.
        "dernier_envoi_de_l_application": clair(fraicheur.get("dernier_envoi"))
        or "jamais : aucune donnée de santé n'a été reçue",
        "periode": f"{du.isoformat()} au {au.isoformat()}",
        "moyennes_7_derniers_jours": _moyennes([j for j in jours
                                                if (au - j["jour"]).days < 7]),
        "moyennes_de_la_periode": _moyennes(jours),
        "jours_sans_donnees": _plages([du + timedelta(days=i)
                                       for i in range((au - du).days + 1)
                                       if du + timedelta(days=i) not in presents]),
        "seances_de_la_montre": [ligne_activite(x) for x in activites],
    }
    if a.get("detail"):
        rendu["jours"] = [sans_vides(clair(j)) for j in jours]
    return rendu


def _allure_en_clair(seance: dict) -> dict:
    """L'allure en minutes par kilomètre, comme on la dit en course (« 5:45 /km »)."""
    secondes = seance.pop("allure_s_km", None)
    if secondes:
        seance["allure"] = f"{secondes // 60}:{secondes % 60:02d} /km"
    duree = seance.get("duree_secondes")
    if duree:
        seance["duree"] = f"{duree // 3600} h {duree % 3600 // 60:02d}" if duree >= 3600 \
            else f"{duree // 60} min {duree % 60:02d} s"
        seance.pop("duree_secondes")
    return seance


def lire_forme(u: int, a: dict) -> object:
    charge = un_seul("SELECT charge_7j, charge_28j, rapport, premier_bilan, seances_7j, "
                     "seances_sans_bilan_28j FROM v_charge_entrainement "
                     "WHERE id_utilisateur = %(u)s", {"u": u}) or {}
    forme = un_seul("SELECT score, etat, sommeil, variabilite, frequence_repos, charge, "
                    "manquantes FROM v_score_forme WHERE id_utilisateur = %(u)s",
                    {"u": u}) or {}
    return {
        "charge": clair(charge) | {
            "note": "Le rapport est vide tant qu'il n'y a pas quatre semaines "
                    "d'historique. Une séance faite sans bilan n'a pas de charge : "
                    "c'est une donnée absente, pas un zéro."},
        "score_de_forme": clair(forme) | {
            "note": "Le ressenti du matin n'est pas recueilli : le score repose sur la "
                    "montre. Ce que dit l'utilisateur passe avant lui."}}


def lire_mesures(u: int, a: dict) -> object:
    type_mesure = a.get("type")
    mesures = lister(
        """SELECT m.id_mesure, m.type_mesure, m.valeur, m.unite, m.cote, m.date_mesure,
                  e.code AS exercice
             FROM mesure m LEFT JOIN exercice e ON e.id_exercice = m.id_exercice
            WHERE m.id_utilisateur = %(u)s
              AND (%(t)s::TEXT IS NULL OR m.type_mesure = %(t)s::TEXT)
            ORDER BY m.date_mesure DESC, m.id_mesure DESC LIMIT 60""",
        {"u": u, "t": type_mesure})
    fenetres = lister(
        """SELECT f.id_fenetre, f.type_mesure, f.periode, f.statut, f.consigne
             FROM fenetre_mesure f
            WHERE f.id_utilisateur = %(u)s
              AND (f.statut = 'ouverte' OR f.date_creation > now() - INTERVAL '21 days')
            ORDER BY f.id_fenetre DESC""", {"u": u})
    return {"mesures": [sans_vides(clair(m)) for m in mesures],
            "fenetres": [sans_vides(clair(f)) for f in fenetres]}


def lire_progression(u: int, a: dict) -> object:
    code = a.get("exercice")
    lignes = lister(
        """SELECT p.code, p.libelle, p.lundi, p.meilleure_charge, p.meilleures_repetitions,
                  p.volume, p.series, p.duree_secondes, p.distance_m
             FROM v_progression p
            WHERE p.id_utilisateur = %(u)s
              AND (%(c)s::TEXT IS NULL OR p.code = %(c)s::TEXT)
              AND p.lundi > jour_de(now()) - 84
            ORDER BY p.code, p.lundi""", {"u": u, "c": code})
    return {"par_exercice_et_par_semaine": [sans_vides(clair(x)) for x in lignes],
            "note": "La charge est commune aux deux côtés. Un exercice absent d'ici n'a "
                    "jamais été saisi : sa première fois se fait au ressenti (PLN-21)."}


def lire_catalogue(u: int, a: dict) -> object:
    lignes = lister(
        """SELECT e.code, e.libelle, e.discipline, e.groupe_principal, e.groupes_secondaires,
                  e.materiel, e.unilateral, e.mesure,
                  e.id_utilisateur IS NOT NULL AS personnel,
                  EXISTS (SELECT 1 FROM serie_saisie ss JOIN occurrence o
                              ON o.id_occurrence = ss.id_occurrence
                           WHERE o.id_utilisateur = %(u)s
                             AND ss.id_exercice = e.id_exercice) AS deja_saisi
             FROM exercice e
            WHERE e.actif
              -- EXO-11 : le catalogue commun, et ce que ce compte y a ajouté.
              AND (e.id_utilisateur IS NULL OR e.id_utilisateur = %(u)s)
              AND (%(d)s::TEXT IS NULL OR e.discipline = %(d)s::TEXT)
              AND (%(g)s::TEXT IS NULL OR e.groupe_principal = %(g)s::TEXT
                   OR %(g)s::TEXT = ANY (e.groupes_secondaires))
              -- Sans ceux qu'une limitation active interdit à ce compte (SEC-1).
              AND NOT EXISTS (SELECT 1 FROM exercice_interdit ei
                                JOIN limitation l ON l.id_limitation = ei.id_limitation
                               WHERE l.id_utilisateur = %(u)s AND l.active
                                 AND ei.id_exercice = e.id_exercice)
            ORDER BY e.discipline, e.groupe_principal, e.libelle""",
        {"u": u, "d": a.get("discipline"), "g": a.get("groupe")})
    return texte_catalogue(lignes)


def texte_catalogue(lignes: list[dict]) -> str:
    """Le catalogue en lignes courtes : le JSON répétait les mêmes clés 98 fois."""
    morceaux = ["Catalogue, une ligne par exercice : code | libellé | groupe principal | "
                "secondaires | matériel | repères. « uni » : un côté à la fois. « saisi » : "
                "déjà fait par l'utilisateur, une charge peut être fixée. « perso » : "
                "ajouté par l'utilisateur, hors du catalogue commun."]
    discipline = None
    for x in lignes:
        if x["discipline"] != discipline:
            discipline = x["discipline"]
            morceaux.append(f"## {discipline}")
        reperes = [m for m, oui in (("uni", x["unilateral"]), ("saisi", x["deja_saisi"]),
                                    ("perso", x.get("personnel"))) if oui]
        if x.get("mesure") and x["mesure"] != "charge_reps":
            reperes.append(f"mesure {x['mesure']}")
        morceaux.append(" | ".join([
            x["code"], x["libelle"], x["groupe_principal"] or "",
            ",".join(x["groupes_secondaires"] or []), x["materiel"] or "",
            " ".join(reperes)]).rstrip(" |"))
    if len(morceaux) == 1:
        morceaux.append("Aucun exercice ne correspond.")
    return "\n".join(morceaux)


# ---------------------------------------------------------------------------
# Écriture : une fonction SQL par outil
# ---------------------------------------------------------------------------

def _sql(requete: str, params: dict) -> dict:
    return executer(requete, params) or {}


def rendre_avis(u: int, a: dict) -> object:
    _sql("SELECT rendre_avis(%(u)s, %(o)s, %(a)s, %(d)s)",
         {"u": u, "o": a.get("id_objectif"), "a": a.get("avis"), "d": a.get("detail")})
    return {"fait": "avis enregistré"}


def ecrire_feuille_de_route(u: int, a: dict) -> object:
    _sql("SELECT ecrire_feuille_de_route(%(u)s, %(t)s)", {"u": u, "t": a.get("texte")})
    return {"fait": "feuille de route écrite"}


def ecrire_trame(u: int, a: dict) -> object:
    semaines = a.get("semaines") or []
    if a.get("nouveau_plan"):
        lundi = _jour(a.get("lundi"), "lundi")
        ligne = _sql(
            "SELECT construire_plan(%(u)s, %(l)s, %(t)s, %(r)s::TEXT[], %(i)s::TEXT[]) AS plan",
            {"u": u, "l": lundi, "t": a.get("trame"),
             "r": [s.get("role") for s in semaines],
             "i": [s.get("intention") for s in semaines]})
        return ligne.get("plan")
    _sql("SELECT reviser_trame(%(u)s, %(t)s, %(s)s)",
         {"u": u, "t": a.get("trame"), "s": Jsonb(semaines)})
    return {"fait": "trame révisée"}


def _seance_rendue(u: int, id_occurrence: int) -> dict:
    ligne = un_seul(
        """SELECT id_occurrence, jour, debut, lieu, discipline, type_seance, intensite,
                  duree_minutes, groupes, situation, exercices
             FROM v_seance_coach WHERE id_utilisateur = %(u)s AND id_occurrence = %(o)s""",
        {"u": u, "o": id_occurrence})
    return sans_vides(clair(ligne or {}))


def proposer_seance(u: int, a: dict) -> object:
    exercices = a.get("exercices")
    ligne = _sql(
        """SELECT proposer_seance(
                      %(u)s, %(discipline)s, %(type)s, %(intensite)s, %(duree)s,
                      %(jour)s, %(hmin)s::TIME, %(hmax)s::TIME, %(lieu)s, %(cle)s, %(test)s,
                      %(groupes)s::TEXT[], %(consigne)s, %(exercices)s, %(remplace)s) AS id""",
        {"u": u, "discipline": a.get("discipline"), "type": a.get("type_seance"),
         "intensite": a.get("intensite"), "duree": a.get("duree_minutes"),
         "jour": _jour(a.get("jour")), "hmin": a.get("heure_min"), "hmax": a.get("heure_max"),
         "lieu": a.get("id_lieu"), "cle": bool(a.get("cle")), "test": bool(a.get("est_test")),
         "groupes": a.get("groupes"), "consigne": a.get("consigne"),
         "exercices": Jsonb(exercices) if exercices else None,
         "remplace": a.get("remplace_id_occurrence")})
    return {"seance_proposee": _seance_rendue(u, ligne["id"])}


def proposer_seances(u: int, a: dict) -> object:
    """COA-29 : plusieurs séances en un appel. Chacune est vérifiée seule, et garde
    son résultat ou son refus : une séance refusée n'empêche pas les autres."""
    seances = a.get("seances") or []
    if not seances or len(seances) > 14:
        raise RefusOutil("requete_invalide", "« seances » contient de 1 à 14 séances")
    resultats = []
    for rang, seance in enumerate(seances, start=1):
        contenu, erreur = executer_outil("proposer_seance", u, seance, {"proposer_seance"})
        rendu = json.loads(contenu)
        resultats.append({"rang": rang, "jour": seance.get("jour"),
                          "type_seance": seance.get("type_seance")}
                         | (rendu if erreur else rendu["seance_proposee"] | {"fait": True}))
    refusees = sum(1 for r in resultats if "refus" in r)
    return {"resultats": resultats,
            "bilan": f"{len(resultats) - refusees} posée(s), {refusees} refusée(s). "
                     "Corrige seulement les refusées."}


def modifier_seance_proposee(u: int, a: dict) -> object:
    champs = {cle: v for cle, v in a.items() if cle != "id_occurrence" and v is not None}
    _sql("SELECT modifier_seance_proposee(%(u)s, %(o)s, %(c)s)",
         {"u": u, "o": a.get("id_occurrence"), "c": Jsonb(champs)})
    return {"seance_modifiee": _seance_rendue(u, int(a["id_occurrence"]))}


def retirer_seance_proposee(u: int, a: dict) -> object:
    _sql("SELECT retirer_seance_proposee(%(u)s, %(o)s)", {"u": u, "o": a.get("id_occurrence")})
    return {"fait": "séance retirée"}


def proposer_ajustement(u: int, a: dict) -> object:
    contenu = a.get("contenu")
    ligne = _sql(
        "SELECT proposer_ajustement(%(u)s, %(o)s, %(n)s, %(c)s, %(m)s) AS id",
        {"u": u, "o": a.get("id_occurrence"), "n": a.get("nature"),
         "c": Jsonb(contenu) if contenu else None, "m": a.get("motif")})
    return {"ajustement_depose": ligne["id"],
            "note": "Il attend la réponse de l'utilisateur : deux boutons lui sont "
                    "présentés avec ton message."}


def rendre_avis_libre(u: int, a: dict) -> object:
    _sql("SELECT rendre_avis_libre(%(u)s, %(o)s, %(a)s, %(d)s)",
         {"u": u, "o": a.get("id_occurrence"), "a": a.get("avis"), "d": a.get("detail")})
    return {"fait": "avis enregistré"}


def ouvrir_fenetre_mesure(u: int, a: dict) -> object:
    ligne = _sql("SELECT ouvrir_fenetre_mesure(%(u)s, %(t)s, %(du)s, %(au)s, %(c)s) AS id",
                 {"u": u, "t": a.get("type"), "du": _jour(a.get("du"), "du"),
                  "au": _jour(a.get("au"), "au"), "c": a.get("consigne")})
    return {"fenetre_ouverte": ligne["id"]}


def noter_mesure(u: int, a: dict) -> object:
    """MES-7 : une mesure dite dans un message (« je pèse 70 kg ») est enregistrée."""
    ligne = _sql("SELECT saisir_mesure(%(u)s, %(t)s, %(v)s, %(un)s, %(c)s, %(d)s) AS id",
                 {"u": u, "t": a.get("type"), "v": a.get("valeur"), "un": a.get("unite"),
                  "c": a.get("cote"),
                  "d": _jour(a["date"], "date") if a.get("date") else None})
    return {"fait": "mesure enregistrée", "id_mesure": ligne.get("id")}


def ecrire_memoire(u: int, a: dict) -> object:
    niveau = a.get("niveau")
    if niveau not in ("semaine", "globale"):
        raise RefusOutil("requete_invalide", "« niveau » vaut semaine ou globale")
    ligne = _sql("SELECT ecrire_memoire(%(u)s, %(n)s, %(t)s, 'coach') AS id",
                 {"u": u, "n": niveau, "t": a.get("texte")})
    return {"fait": f"mémoire {niveau} écrite", "version": ligne["id"]}


def ajouter_memoire(u: int, a: dict) -> object:
    """MEM-9 : une ligne ajoutée à la mémoire de la semaine, sans la réécrire."""
    from api.coach import memoire
    ligne = (a.get("ligne") or "").strip()
    if not ligne:
        raise RefusOutil("requete_invalide", "« ligne » est vide")
    actuelle = memoire.en_vigueur(u, "semaine", lundi_de(aujourd_hui()))
    texte = ((actuelle or {}).get("texte") or "").rstrip()
    nouveau = (texte + "\n" if texte else "") + "- " + ligne.lstrip("- ")
    rendu = _sql("SELECT ecrire_memoire(%(u)s, 'semaine', %(t)s, 'coach') AS id",
                 {"u": u, "t": nouveau})
    return {"fait": "ligne ajoutée à la mémoire de la semaine", "version": rendu["id"],
            "longueur": len(nouveau)}


def marquer_important(u: int, a: dict) -> object:
    _sql("SELECT marquer_important(%(u)s, %(r)s)", {"u": u, "r": a.get("raison")})
    return {"fait": "échange marqué important : les résumés le garderont"}


def requalifier_en_signalement(u: int, a: dict) -> object:
    # L'effet est dans la boucle : c'est elle qui change de moment (COA-25).
    return {"fait": "requalifié"}


# ---------------------------------------------------------------------------
# Le catalogue des outils
# ---------------------------------------------------------------------------

_EXERCICES = {
    "type": "array",
    "description": "Exercices dans l'ordre, ou blocs d'une séance de course. Codes du "
                   "catalogue. Charge, séries et répétitions valent pour les deux côtés.",
    "items": _objet({
        "code": {"type": "string", "description": "Code de l'exercice au catalogue"},
        "series": {"type": "integer", "minimum": 1},
        "repetitions_min": {"type": "integer", "minimum": 1},
        "repetitions_max": {"type": "integer", "minimum": 1},
        "charge_kg": {"type": "number", "minimum": 0,
                      "description": "Pas en calibrage ni sur un exercice jamais saisi"},
        "duree_secondes": {"type": "integer", "minimum": 1},
        "distance_m": {"type": "integer", "minimum": 1},
        "repos_secondes": {"type": "integer", "minimum": 0},
        "marge_repetitions": {"type": "integer", "minimum": 0, "maximum": 5},
        "cible": {"type": "string", "description": "Allure ou zone, 60 caractères"},
        "consigne": {"type": "string"},
    }, ["code"]),
}

_PLAGE = {
    "jour": {"type": "string", "description": "AAAA-MM-JJ"},
    "heure_min": {"type": "string", "description": "Début de la plage, HH:MM"},
    "heure_max": {"type": "string",
                  "description": "Fin de la plage, HH:MM. La séance entière doit y tenir. "
                                 "La base choisit dans la plage le début qui tient."},
    "id_lieu": {"type": "integer",
                "description": "Un lieu de la discipline. Sans lui, le premier du rang."},
}

_SEANCE = _objet(
    {"discipline": {"type": "string", "enum": DISCIPLINES},
     "type_seance": {"type": "string",
                     "description": "Nom court, 40 caractères : « haut du corps », "
                                    "« sortie longue », « seuil »"},
     "intensite": {"type": "string", "enum": INTENSITES},
     "duree_minutes": {"type": "integer", "minimum": 15, "maximum": 240},
     **_PLAGE,
     "cle": {"type": "boolean", "description": "Séance clé de la semaine"},
     "est_test": {"type": "boolean"},
     "groupes": {"type": "array", "items": {"type": "string", "enum": GROUPES}},
     "consigne": {"type": "string"},
     "exercices": _EXERCICES,
     "remplace_id_occurrence": {"type": "integer",
                                "description": "La séance pas faite que celle-ci remplace"}},
    ["discipline", "type_seance", "intensite", "duree_minutes", "jour",
     "heure_min", "heure_max"])

OUTILS: tuple[Outil, ...] = (
    Outil("lire_chapitre", "lecture",
          "Rend le texte d'un chapitre du dossier, par son numéro (par exemple 4.7). "
          "Le socle et les paquets joints à cet appel sont déjà dans la consigne.",
          _objet({"numero": {"type": "string"}}, ["numero"]), lire_chapitre),
    Outil("lire_echanges", "lecture",
          "Cherche dans tous vos échanges passés, au-delà des derniers que tu as sous "
          "les yeux : par mot (« genou »), par période, ou seulement les importants "
          "(importance_min 2 ou 3). Du plus ancien au plus récent, 20 au plus.",
          _objet({"cherche": {"type": "string"},
                  "du": {"type": "string", "description": "AAAA-MM-JJ"},
                  "au": {"type": "string", "description": "AAAA-MM-JJ"},
                  "importance_min": {"type": "integer", "minimum": 1, "maximum": 3},
                  "limite": {"type": "integer", "minimum": 1, "maximum": 20}}),
          lire_echanges),
    Outil("lire_planning", "lecture",
          "Emploi du temps, absences et charge de chaque journée (légère, moyenne, "
          "lourde) sur une période de 35 jours au plus.",
          _objet({"du": {"type": "string", "description": "AAAA-MM-JJ"},
                  "au": {"type": "string", "description": "AAAA-MM-JJ"}}, ["du", "au"]),
          lire_planning),
    Outil("lire_semaine", "lecture",
          "Les séances d'une semaine : leur état (esquisse, proposée, validée, faite, "
          "pas faite, remplacée), leur contenu résumé, ce qui a été fait, les "
          "ajustements. Sans lundi, la semaine en cours.",
          _objet({"lundi": {"type": "string", "description": "AAAA-MM-JJ"}}), lire_semaine),
    Outil("lire_seance", "lecture",
          "Une séance en détail : exercices prévus, séries saisies, bilan, séance de la "
          "montre rattachée. Une course y est lue étape par étape, face au prévu.",
          _objet({"id_occurrence": {"type": "integer"}}, ["id_occurrence"]), lire_seance),
    Outil("lire_courses", "lecture",
          "Les dernières courses de la montre, chacune lue étape par étape : fractions "
          "et leurs temps face à l'objectif, FC en fin de fraction et en récupération, "
          "dérive cardiaque d'une sortie continue, zones. Sans dates, les 42 derniers "
          "jours ; 6 courses par défaut, 12 au plus. detail à vrai : aussi chaque "
          "étape, chaque kilomètre et la dynamique de course.",
          _objet({"du": {"type": "string", "description": "AAAA-MM-JJ"},
                  "au": {"type": "string", "description": "AAAA-MM-JJ"},
                  "nombre": {"type": "integer", "minimum": 1, "maximum": 12},
                  "detail": {"type": "boolean"}}), lire_courses),
    Outil("lire_sante", "lecture",
          "Moyennes de pas, sommeil, FC de repos et variabilité (7 jours et période), "
          "jours sans données, séances de la montre une par ligne, dernier envoi. Sans "
          "dates, les 28 derniers jours. detail à vrai : aussi chaque jour.",
          _objet({"du": {"type": "string"}, "au": {"type": "string"},
                  "detail": {"type": "boolean"}}), lire_sante),
    Outil("lire_forme", "lecture",
          "Charge d'entraînement sur 7 et 28 jours, leur rapport, score de forme et "
          "composantes manquantes.", _objet({}), lire_forme),
    Outil("lire_mesures", "lecture",
          "L'historique des mesures (poids, tours, tests) et les fenêtres de mesure.",
          _objet({"type": {"type": "string", "enum": TYPES_MESURE}}), lire_mesures),
    Outil("lire_progression", "lecture",
          "Par exercice et par semaine : meilleure charge, volume, séries saisies, sur "
          "douze semaines. Sans exercice, tous ceux qui ont été saisis.",
          _objet({"exercice": {"type": "string", "description": "Code au catalogue"}}),
          lire_progression),
    Outil("lire_catalogue", "lecture",
          "Les exercices actifs du catalogue, sans ceux qu'une limitation interdit à "
          "l'utilisateur. Une séance ne se compose qu'avec ces codes.",
          _objet({"discipline": {"type": "string", "enum": DISCIPLINES},
                  "groupe": {"type": "string", "enum": GROUPES + ["cardio"]}}),
          lire_catalogue),

    Outil("rendre_avis", "avis",
          "Enregistre ton avis sur un objectif : réaliste, ambitieux ou irréaliste, "
          "avec l'ajustement que tu proposes. L'avis ne bloque rien.",
          _objet({"id_objectif": {"type": "integer"},
                  "avis": {"type": "string", "enum": ["realiste", "ambitieux", "irrealiste"]},
                  "detail": {"type": "string"}}, ["id_objectif", "avis", "detail"]),
          rendre_avis),

    Outil("ecrire_feuille_de_route", "trame",
          "Écrit ou révise le chemin jusqu'à l'échéance de l'objectif principal, par "
          "grandes phases. Elle te sera rendue à chaque appel.",
          _objet({"texte": {"type": "string"}}, ["texte"]), ecrire_feuille_de_route),
    Outil("ecrire_trame", "trame",
          "Avec nouveau_plan à vrai : crée le plan de quatre semaines (lundi de cette "
          "semaine ou le suivant), sa trame et le rôle de chacune des quatre semaines, "
          "dans l'ordre. Le plan précédent est clos. Sans nouveau_plan : révise la trame "
          "du plan en cours, ou le rôle de semaines non validées (donner leur lundi).",
          _objet({"nouveau_plan": {"type": "boolean"},
                  "lundi": {"type": "string", "description": "AAAA-MM-JJ, pour un nouveau plan"},
                  "trame": {"type": "string",
                            "description": "Ce que le mois doit produire, et pourquoi"},
                  "semaines": {"type": "array", "items": _objet({
                      "lundi": {"type": "string"},
                      "role": {"type": "string", "enum": ROLES},
                      "intention": {"type": "string"}}, ["role"])}}),
          ecrire_trame),

    Outil("proposer_seance", "seances",
          "Propose une séance : une discipline, un jour, une plage d'heures et son "
          "contenu. La base vérifie le lieu, le placement, les exercices et la sécurité, "
          "et rend le motif si elle refuse. Sans exercices, c'est une esquisse : donner "
          "alors les groupes sollicités (musculation).",
          _SEANCE,
          proposer_seance, cache=True),
    Outil("proposer_seances", "seances",
          "Propose une ou plusieurs séances (une seule, une semaine, ou les esquisses de "
          "plusieurs semaines) : une discipline, un jour, une plage d'heures et le "
          "contenu de chacune. Sans exercices, c'est une esquisse : donner alors les "
          "groupes sollicités (musculation). La base vérifie le lieu, le placement, les "
          "exercices et la sécurité, une séance à la fois, et rend pour chacune la "
          "séance posée ou le motif du refus.",
          _objet({"seances": {"type": "array", "minItems": 1, "maxItems": 14,
                              "items": _SEANCE}}, ["seances"]),
          proposer_seances),
    Outil("modifier_seance_proposee", "seances",
          "Change une séance encore proposée : contenu, durée, lieu, jour ou plage "
          "d'heures. C'est aussi par là qu'une esquisse reçoit ses exercices. Ne donner "
          "que ce qui change. Refusé sur une séance validée.",
          _objet({"id_occurrence": {"type": "integer"},
                  "type_seance": {"type": "string"},
                  "intensite": {"type": "string", "enum": INTENSITES},
                  "duree_minutes": {"type": "integer", "minimum": 15, "maximum": 240},
                  **_PLAGE,
                  "cle": {"type": "boolean"},
                  "groupes": {"type": "array", "items": {"type": "string", "enum": GROUPES}},
                  "consigne": {"type": "string"},
                  "exercices": _EXERCICES}, ["id_occurrence"]),
          modifier_seance_proposee),
    Outil("retirer_seance_proposee", "seances",
          "Retire une séance encore proposée. Refusé sur une séance validée.",
          _objet({"id_occurrence": {"type": "integer"}}, ["id_occurrence"]),
          retirer_seance_proposee),
    Outil("proposer_ajustement", "seances",
          "Dépose un ajustement sur une séance validée : alléger (seulement réduire), "
          "modifier le contenu, déplacer, ou retirer. L'utilisateur accepte ou refuse "
          "d'un bouton. Sans réponse quand la séance commence, seul un allègement ou un "
          "retrait s'applique. Contenu : pour alléger ou modifier, duree_minutes, "
          "intensite, type_seance, consigne, exercices ; pour déplacer, jour, heure_min, "
          "heure_max, id_lieu ; rien pour retirer.",
          _objet({"id_occurrence": {"type": "integer"},
                  "nature": {"type": "string",
                             "enum": ["alleger", "modifier", "deplacer", "retirer"]},
                  "contenu": _objet({
                      "duree_minutes": {"type": "integer"},
                      "intensite": {"type": "string", "enum": INTENSITES},
                      "type_seance": {"type": "string"},
                      "consigne": {"type": "string"},
                      "exercices": _EXERCICES,
                      **_PLAGE}),
                  "motif": {"type": "string"}}, ["id_occurrence", "nature", "motif"]),
          proposer_ajustement),

    Outil("rendre_avis_libre", "avis_libre",
          "Enregistre ton avis sur une séance libre : conforme, acceptable, ou à éviter "
          "la prochaine fois, avec la raison. Jamais un refus.",
          _objet({"id_occurrence": {"type": "integer"},
                  "avis": {"type": "string", "enum": ["conforme", "acceptable", "a_eviter"]},
                  "detail": {"type": "string"}}, ["id_occurrence", "avis", "detail"]),
          rendre_avis_libre),

    Outil("ouvrir_fenetre_mesure", "fenetre",
          "Ouvre une fenêtre de mesure de deux ou trois jours (sept au plus), avec sa "
          "consigne. Une seule fenêtre ouverte par type. Un test de course ou de force "
          "est une séance du plan (proposer_seance avec est_test) : propose-la d'abord, "
          "la fenêtre se rattache à elle et prend son jour.",
          _objet({"type": {"type": "string", "enum": TYPES_MESURE},
                  "du": {"type": "string"}, "au": {"type": "string"},
                  "consigne": {"type": "string"}}, ["type", "du", "au"]),
          ouvrir_fenetre_mesure),

    Outil("noter_mesure", "mesure",
          "Enregistre une mesure que l'utilisateur te donne dans son message : poids, "
          "tour de taille, de bras, temps d'un test. Sans date, aujourd'hui. Une "
          "mesure de bras ou de cuisse se donne par côté.",
          _objet({"type": {"type": "string", "enum": TYPES_MESURE},
                  "valeur": {"type": "number"},
                  "unite": {"type": "string", "description": "kg, cm, s"},
                  "cote": {"type": "string", "enum": ["gauche", "droite"]},
                  "date": {"type": "string", "description": "AAAA-MM-JJ"}},
                 ["type", "valeur", "unite"]),
          noter_mesure),

    Outil("ecrire_memoire", "memoire",
          "Réécrit en entier un étage de ta mémoire, en repartant du texte actuel. "
          "« semaine » : 3 000 caractères, pour corriger ou condenser. « globale » : "
          "4 000 caractères, ce qui est durable sur la personne, ou pour oublier ce "
          "qu'elle demande. « (déduit) » après une déduction, « (à confirmer) » si elle "
          "n'est pas confirmée.",
          _objet({"niveau": {"type": "string", "enum": ["semaine", "globale"]},
                  "texte": {"type": "string"}}, ["niveau", "texte"]),
          ecrire_memoire),
    Outil("ajouter_memoire", "memoire",
          "Ajoute une ligne à la mémoire de la semaine, sans la réécrire : un fait dit "
          "par l'utilisateur, une décision et sa raison. À préférer à ecrire_memoire "
          "dès qu'il n'y a rien à corriger dans le texte actuel.",
          _objet({"ligne": {"type": "string"}}, ["ligne"]), ajouter_memoire),
    Outil("marquer_important", "memoire",
          "Marque l'échange en cours comme important : les résumés de la mémoire le "
          "garderont toujours. Un objectif, un plan ou un ajustement le sont déjà "
          "d'office. À utiliser pour ce qui ne laisse pas de trace en base : une "
          "décision de l'utilisateur, une douleur nouvelle, un changement de vie.",
          _objet({"raison": {"type": "string"}}, ["raison"]), marquer_important),

    Outil("requalifier_en_signalement", "requalification",
          "Dans le chat seulement : dit que le texte reçu est en fait un signalement "
          "(une douleur, une fatigue, un contretemps, ou la réponse à une question que "
          "tu as posée dans une synthèse). Tu reçois alors les outils du signalement et "
          "tu traites le texte tout de suite. À appeler avant de répondre.",
          _objet({"raison": {"type": "string"}}, ["raison"]), requalifier_en_signalement),
)

PAR_NOM = {outil.nom: outil for outil in OUTILS}


def tous_les_outils() -> tuple[Outil, ...]:
    """Ceux du coach, et les demandes (ACC). Importées ici : `api.demandes` appelle
    les routes, qui importent ce module."""
    from api import demandes
    return (*OUTILS, *demandes.OUTILS, *demandes.OUTILS_GESTES_SPORT)


def catalogue_avec(permis: list[Outil]) -> dict[str, Outil]:
    """Tous les outils du coach, et ceux du moment : un outil du HAL du foyer n'est
    pas dans le catalogue du coach, et un outil hors du moment reste « non permis »
    plutôt qu'« inconnu »."""
    return {**{o.nom: o for o in tous_les_outils()}, **{o.nom: o for o in permis}}


def outils_du_moment(moment: str, en_pause: bool = False) -> list[Outil]:
    """COA-5, PAU-2 : les outils permis pour ce moment."""
    familles = set(FAMILLES_DU_MOMENT[moment])
    if en_pause:
        familles -= FERMEES_EN_PAUSE
    return [outil for outil in tous_les_outils() if outil.famille in familles]


def executer_outil(nom: str, id_utilisateur: int, arguments: dict,
                   permis: set[str], catalogue: dict[str, Outil] | None = None
                   ) -> tuple[str, bool]:
    """Exécute un outil et rend son résultat en texte, et s'il s'agit d'un refus.

    Un outil inconnu, un outil qui n'est pas permis pour ce moment, un refus de
    la base : dans tous les cas le modèle reçoit un motif qu'il peut lire.

    `catalogue` est celui du serveur MCP (MCP-5) : mêmes outils pour la plupart,
    et ceux du planning et de la maison en plus. Sans lui, celui du coach.
    """
    outil = (catalogue or {o.nom: o for o in tous_les_outils()}).get(nom)
    if outil is None:
        return _refus("outil_inconnu", f"L'outil « {nom} » n'existe pas"), True
    if nom not in permis:
        return _refus("outil_non_permis",
                      f"L'outil « {nom} » n'est pas permis à ce moment"), True
    try:
        resultat = outil.fonction(id_utilisateur, arguments or {})
    except RefusOutil as refus:
        return _refus(refus.code, refus.motif), True
    except psycopg.Error as erreur:
        refus = refus_coach(erreur)
        if refus is not None:
            _noter_le_refus(nom, refus["code"], refus["message"])
            return _refus(refus["code"], refus["message"]), True
        if (erreur.sqlstate or "").startswith(("22", "23", "P0")):
            # Une valeur hors de sa liste, une date impossible : la base le dit.
            return _refus("requete_invalide", message_lisible(erreur)), True
        raise
    except (TypeError, ValueError, KeyError) as erreur:
        return _refus("requete_invalide", f"Arguments invalides : {erreur}"), True

    if isinstance(resultat, str):
        return resultat, False
    return json.dumps(clair(resultat), ensure_ascii=False), False


def _refus(code: str, motif: str) -> str:
    return json.dumps({"refus": code, "motif": motif}, ensure_ascii=False)


SECURITE = {"exercice_interdit", "seances_dures_collees"}


def _noter_le_refus(outil: str, code: str, motif: str) -> None:
    """SEC-5 : un refus de sécurité est noté au journal, dans l'opération du coach.

    Un coach qui se heurte souvent à la même règle signale un dossier à corriger.
    La ligne est technique : seul l'administrateur la lit.
    """
    if code not in SECURITE:
        return
    try:
        executer("SELECT noter_evenement('coach', %(l)s, %(d)s, TRUE)",
                 {"l": f"Refus de sécurité ({code}) sur {outil}", "d": motif})
    except psycopg.Error:
        pass
