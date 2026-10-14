"""Remplit la fausse base de la maquette avec des données inventées.

    ./outils/fausse_base.sh          crée la base, puis lance ce fichier

Ne se lance jamais seul sur une vraie base : il s'arrête si la base visée ne
s'appelle pas « planif_maquette ». Tout est inventé, rien ne vient de Santé ni
d'un vrai calendrier. Les dates partent d'aujourd'hui, pour que la base reste
valable demain.

Le remplissage passe par les fonctions de la base (proposer_seance,
construire_plan, saisir_mesure, ouvrir_fenetre_mesure, valider_occurrence...)
pour que chaque état soit un état que la base autorise. Trois exceptions,
faute de fonction, faites comme le font les tests :

  - le conflit de cours, que seule la collecte d'un calendrier fabrique ;
  - deux tâches mises en retard, en reculant leur fenêtre comme si les jours
    avaient passé ;
  - les échanges avec HAL, écrits comme si HAL avait répondu, sans appeler le
    modèle. Leurs éléments, eux, sont relus en base par `reponse.elements_de`,
    avec leurs vrais boutons.

Les comptes, à taper dans l'appli (serveur http://localhost:8000) :

    thomas   / maquette-thomas      administrateur, HAL démarré
    lorette  / maquette-lorette     HAL pas démarré
"""

import hashlib
import json
import math
import secrets
import uuid
from datetime import date, datetime, time, timedelta

from psycopg.types.json import Jsonb

from api import mot_de_passe, operation
from api.base import executer
from api.coach import dossier, reponse
from api.coach.clair import aujourd_hui, fuseau, lundi_de
from api.config import configuration

MOTS_DE_PASSE = {"thomas": "maquette-thomas", "lorette": "maquette-lorette"}
MODELE = "maquette"

J = aujourd_hui()
LUNDI = lundi_de(J)


def sql(requete: str, **p):
    return executer(requete, p)


def un(requete: str, **p):
    ligne = executer(requete, p)
    return next(iter(ligne.values())) if ligne else None


def a(jour: date, heure: int, minute: int = 0) -> datetime:
    return datetime.combine(jour, time(heure, minute), tzinfo=fuseau())


def dire(texte: str) -> None:
    print(f"· {texte}", flush=True)


# ---------------------------------------------------------------------------
# Les comptes
# ---------------------------------------------------------------------------

def cle_fixe(pseudo: str) -> str:
    """Une clé d'API qui ne change pas d'une fausse base à l'autre : l'appli du
    simulateur reste connectée quand on refait la base. Fausse base seulement."""
    return hashlib.sha256(f"maquette-{pseudo}".encode()).hexdigest()


def comptes() -> tuple[int, int]:
    for pseudo, nom, role in (("thomas", "Thomas", "admin"), ("lorette", "Lorette", "standard")):
        sql("""INSERT INTO utilisateur (pseudo, nom, role, cle_api, jeton_calendrier)
               VALUES (%(p)s, %(n)s, %(r)s, %(c)s, %(j)s)""",
            p=pseudo, n=nom, r=role, c=cle_fixe(pseudo), j=secrets.token_hex(16))
    sql("SELECT amorcer_foyer()")
    sql("SELECT appliquer_assignations()")
    sql("SELECT assigner_calendriers_perso()")
    t = un("SELECT id_utilisateur FROM utilisateur WHERE pseudo = 'thomas'")
    lo = un("SELECT id_utilisateur FROM utilisateur WHERE pseudo = 'lorette'")
    for pseudo, mdp in MOTS_DE_PASSE.items():
        mot_de_passe.choisir(t if pseudo == "thomas" else lo, mdp)

    # Des adresses qui ne mènent nulle part : l'amorçage de l'API ne remplit
    # que les sources sans adresse, il n'y écrira donc pas les vraies.
    sql("""UPDATE source
              SET url = 'https://exemple.invalid/' || lower(code) || '.ics',
                  active = TRUE, etat = 'ok', derniere_collecte = now()
            WHERE mode_collecte = 'ics' AND code <> 'PERSO_LORETTE_BABYSITTING'""")
    dire("comptes thomas et lorette, un foyer, des calendriers fictifs")
    return t, lo


# ---------------------------------------------------------------------------
# Le planning
# ---------------------------------------------------------------------------

# Par jour de la semaine (0 = lundi) : début, fin, titre, salle.
COURS_THOMAS = {
    0: [((8, 0), (10, 0), "CM Réseaux", "Amphi 2"),
        ((10, 15), (12, 15), "TD Algo IA", "Salle 223/224"),
        ((14, 0), (16, 0), "TP Bases de données", "Salle 105")],
    1: [((9, 0), (12, 0), "Projet tutoré", "Salle 310"),
        ((13, 30), (15, 30), "CM Systèmes", "Amphi 1")],
    2: [((8, 0), (10, 0), "TD Réseaux", "Salle 214"),
        ((15, 30), (17, 30), "TD Algo IA", "Salle 223/224")],
    3: [((10, 15), (12, 15), "CM Intelligence artificielle", "Amphi 2"),
        ((13, 45), (15, 45), "TP Systèmes", "Salle 105"),
        ((16, 0), (18, 0), "Anglais", "Salle 012")],
    4: [((8, 0), (12, 0), "TP Projet", "Salle 310")],
}
TRAVAIL_LORETTE = {
    0: [((9, 0), (17, 30), "Stage · cabinet", "Nancy")],
    1: [((9, 0), (17, 30), "Stage · cabinet", "Nancy")],
    2: [((9, 0), (12, 30), "Stage · cabinet", "Nancy")],
    3: [((9, 0), (17, 30), "Stage · cabinet", "Nancy")],
    4: [((9, 0), (16, 0), "Stage · cabinet", "Nancy")],
}


def planning(t: int, lo: int) -> None:
    for qui, grille, genre in ((t, COURS_THOMAS, "cours"), (lo, TRAVAIL_LORETTE, "travail")):
        for decalage in range(-14, 29):
            jour = J + timedelta(days=decalage)
            for (h1, m1), (h2, m2), titre, salle in grille.get(jour.weekday(), []):
                sql("SELECT ajouter_occupation(%(u)s, %(l)s, %(d)s, %(f)s, %(t)s, %(s)s)",
                    u=qui, l=titre, d=a(jour, h1, m1), f=a(jour, h2, m2), t=genre, s=salle)
    # Un rendez-vous ce soir, pour que « Maintenant » ait quelque chose ensuite.
    sql("SELECT ajouter_occupation(%(u)s, 'Dentiste', %(d)s, %(f)s, 'autre', 'Cabinet Stanislas')",
        u=t, d=a(J + timedelta(days=1), 18, 30), f=a(J + timedelta(days=1), 19, 15))

    # COL-12 : un cours du calendrier qui chevauche un cours déjà connu. Seule
    # la collecte d'un flux en fabrique : on le pose comme elle le ferait.
    jour = J + timedelta(days=1)
    while jour.weekday() not in COURS_THOMAS:
        jour += timedelta(days=1)
    (h1, m1), (h2, m2), titre, _ = COURS_THOMAS[jour.weekday()][0]
    sql("""INSERT INTO conflit (id_occupation, id_source, cle_externe, libelle, periode, lieu,
                                details)
           SELECT oc.id_occupation, s.id_source, 'maquette-conflit', 'Partiel blanc · Réseaux',
                  tstzrange(%(d)s, %(f)s, '[)'), 'Amphi 1', 'Ajouté par la scolarité'
             FROM occupation oc, source s
            WHERE oc.id_utilisateur = %(u)s AND oc.libelle = %(l)s
              AND lower(oc.periode) = %(debut)s AND s.code = 'PERSO_THOMAS'""",
        u=t, l=titre, debut=a(jour, h1, m1),
        d=a(jour, h1, m1) + timedelta(minutes=30), f=a(jour, h2, m2) + timedelta(minutes=30))
    dire("cours et stage sur six semaines, un conflit de cours à trancher")


def maison(t: int, lo: int) -> None:
    # Ce qui a été fait la semaine passée, pour l'équilibre et l'historique.
    for qui, code, jours in ((t, "ASPIRATEUR", 3), (t, "LITIERE_CROTTES", 1),
                             (t, "LITIERE_CROTTES", 3), (t, "LAVE_VAISSELLE", 2),
                             (lo, "PLIER_LINGE", 2), (lo, "POUSSIERE", 4),
                             (lo, "LESSIVE_BLANC", 5), (lo, "EAU_SASSY", 2)):
        sql("SELECT declarer_faite(%(u)s, %(c)s, %(q)s)", u=qui, c=code,
            q=a(J - timedelta(days=jours), 19, 0))

    sql("SELECT generer_occurrences(35)")
    sql("SELECT placer_taches(35, 7)")

    # Deux tâches en retard : leur fenêtre recule comme si les jours avaient
    # passé, comme dans les tests. La base les dit alors en retard d'elle-même.
    for code, jours in (("RECURAGE", 2), ("DRAPS", 1)):
        sql("""UPDATE occurrence o
                  SET fenetre = tstzrange(%(d)s, %(f)s, '[)'),
                      creneau = tstzrange(%(d)s, %(d)s + INTERVAL '30 minutes', '[)')
                WHERE o.id_occurrence = (
                      SELECT o2.id_occurrence FROM occurrence o2 JOIN tache ta USING (id_tache)
                       WHERE ta.code = %(c)s AND o2.statut IN ('planifiee', 'notifiee')
                       ORDER BY lower(COALESCE(o2.creneau, o2.fenetre)) LIMIT 1)""",
            c=code, d=a(J - timedelta(days=jours + 2), 10), f=a(J - timedelta(days=jours), 22))

    # Deux tâches du jour déjà faites, une par personne.
    for qui, code in ((t, "LAVE_VAISSELLE"), (lo, "EAU_SASSY")):
        o = un("""SELECT o.id_occurrence FROM occurrence o JOIN tache ta USING (id_tache)
                   WHERE ta.code = %(c)s AND o.statut IN ('planifiee', 'notifiee')
                   ORDER BY lower(COALESCE(o.creneau, o.fenetre)) LIMIT 1""", c=code)
        if o:
            sql("SELECT valider_occurrence(%(o)s, %(u)s, now())", o=o, u=qui)

    # Lorette part un week-end, et allège sa semaine.
    samedi = J + timedelta(days=(5 - J.weekday()) % 7 + 7)
    sql("""INSERT INTO absence (id_utilisateur, periode, lieu, origine)
           VALUES (%(u)s, tstzrange(%(d)s, %(f)s, '[)'), 'Lusse', 'manuelle')""",
        u=lo, d=a(samedi - timedelta(days=1), 18), f=a(samedi + timedelta(days=1), 20))
    sql("SELECT activer_allegement(%(u)s, 3)", u=lo)

    # Un train retenu par Thomas pour le week-end de Lorette à Lusse. Comme le
    # conflit, ces horaires viennent d'ordinaire de la SNCF : on les pose tels
    # qu'elle les donnerait, puis la base les retient par sa fonction.
    aller = un("""INSERT INTO trajet (id_utilisateur, sens, periode, origine, destination,
                                      correspondances, resume)
                  VALUES (%(u)s, 'aller', tstzrange(%(d)s, %(a)s, '[)'), 'Nancy',
                          'Saint-Dié-des-Vosges', 0, 'TER 835412')
                  RETURNING id_trajet""",
               u=t, d=a(samedi - timedelta(days=1), 17, 42), a=a(samedi - timedelta(days=1), 19, 6))
    retour = un("""INSERT INTO trajet (id_utilisateur, sens, periode, origine, destination,
                                       correspondances, resume, id_trajet_aller)
                   VALUES (%(u)s, 'retour', tstzrange(%(d)s, %(a)s, '[)'), 'Saint-Dié-des-Vosges',
                           'Nancy', 0, 'TER 835437', %(al)s)
                   RETURNING id_trajet""",
                u=t, d=a(samedi + timedelta(days=1), 18, 10),
                a=a(samedi + timedelta(days=1), 19, 34), al=aller)
    sql("SELECT retenir_trajet(%(a)s, %(r)s)", a=aller, r=retour)

    n = un("SELECT count(*) FROM proposer_weekends(%(u)s, 'Lusse')", u=t)
    sql("SELECT placer_taches(35, 7)")
    dire(f"tâches placées, deux en retard, deux faites, une absence, le mode allégé, "
         f"{n} week-end(s) proposé(s)")


# ---------------------------------------------------------------------------
# Le sport et HAL, pour Thomas
# ---------------------------------------------------------------------------

def lieu(code: str) -> int:
    return un("SELECT id_lieu FROM lieu_sport WHERE code = %(c)s", c=code)


def exo(code: str) -> int:
    return un("SELECT id_exercice FROM exercice WHERE code = %(c)s", c=code)


HAUT = [{"code": "developpe_couche_barre", "series": 4, "repetitions_min": 6,
         "repetitions_max": 8},
        {"code": "tractions_pronation", "series": 3, "repetitions_min": 6,
         "repetitions_max": 10},
        {"code": "developpe_militaire_barre", "series": 3, "repetitions_min": 8,
         "repetitions_max": 10},
        {"code": "rowing_haltere_un_bras", "series": 3, "repetitions_min": 10,
         "repetitions_max": 12},
        {"code": "curl_marteau", "series": 2, "repetitions_min": 10, "repetitions_max": 12}]
BAS = [{"code": "squat_barre", "series": 4, "repetitions_min": 6, "repetitions_max": 8},
       {"code": "souleve_de_terre_roumain", "series": 3, "repetitions_min": 8,
        "repetitions_max": 10},
       {"code": "fentes_halteres", "series": 3, "repetitions_min": 10, "repetitions_max": 12},
       {"code": "mollets_debout", "series": 3, "repetitions_min": 12, "repetitions_max": 15},
       {"code": "planche", "series": 3, "repetitions_min": 1, "repetitions_max": 1}]
COURSE_EF = [{"code": "course_echauffement", "series": 1, "duree_secondes": 600},
             {"code": "course_endurance", "series": 1, "duree_secondes": 1800},
             {"code": "course_retour_au_calme", "series": 1, "duree_secondes": 300}]
COURSE_FRAC = [{"code": "course_echauffement", "series": 1, "duree_secondes": 900},
               {"code": "course_fractionne_duree", "series": 6, "duree_secondes": 120},
               {"code": "course_retour_au_calme", "series": 1, "duree_secondes": 300}]
TEST = [{"code": "course_echauffement", "series": 1, "duree_secondes": 900},
        {"code": "course_test", "series": 1, "distance_m": 5000}]

# Les charges de départ de chaque exercice, en kg, et leur progression par séance.
CHARGES = {"developpe_couche_barre": (62.5, 2.5), "tractions_pronation": (0, 0),
           "developpe_militaire_barre": (37.5, 1.25), "rowing_haltere_un_bras": (24, 2),
           "curl_marteau": (12, 1), "squat_barre": (80, 2.5),
           "souleve_de_terre_roumain": (70, 2.5), "fentes_halteres": (16, 2),
           "mollets_debout": (60, 5), "planche": (None, 0)}


def proposer(u: int, discipline: str, titre: str, jour: date, exercices, intensite="moderee",
             duree=60, plage=("17:00", "21:00"), test=False, groupes=None,
             consigne=None) -> int:
    return un("""SELECT proposer_seance(%(u)s, %(d)s, %(t)s, %(i)s, %(du)s, %(j)s,
                                        %(h1)s::TIME, %(h2)s::TIME, NULL, FALSE, %(test)s,
                                        %(g)s::TEXT[], %(c)s, %(e)s::JSONB)""",
              u=u, d=discipline, t=titre, i=intensite, du=duree, j=jour, h1=plage[0],
              h2=plage[1], test=test, g=groupes, c=consigne, e=json.dumps(exercices))


def reculer(o: int, de: timedelta) -> None:
    """Fait comme si la séance avait été prévue plus tôt, comme le font les tests."""
    sql("""UPDATE occurrence
              SET debut_seance = debut_seance - %(r)s,
                  creneau = tstzrange(lower(creneau) - %(r)s, upper(creneau) - %(r)s, '[)'),
                  fenetre = tstzrange(lower(fenetre) - %(r)s, upper(fenetre) - %(r)s, '[)')
            WHERE id_occurrence = %(o)s""", o=o, r=de)


def proposer_valider(u: int, discipline: str, titre: str, jour: date, exercices,
                     **options) -> int:
    """Une séance validée à ce jour. La base refuse de proposer dans le passé :
    un jour passé, ou un soir déjà commencé, se propose trois semaines plus
    tard puis se recule à son jour."""
    try:
        o = proposer(u, discipline, titre, jour, exercices, **options)
        sql("SELECT valider_seance(%(u)s, %(o)s)", u=u, o=o)
        return o
    except Exception as erreur:
        if "déjà passé" not in str(erreur):
            raise
    o = proposer(u, discipline, titre, jour + timedelta(days=21), exercices, **options)
    sql("SELECT valider_seance(%(u)s, %(o)s)", u=u, o=o)
    reculer(o, timedelta(days=21))
    return o


def faire_muscu(u: int, o: int, exercices: list[dict], rang: int, effort: int,
                commentaire: str) -> None:
    """Les séries d'une séance passée, puis son bilan. Une séance prévue
    rattache chaque série à sa ligne ; une séance libre gagne ses exercices."""
    debut = un("""SELECT COALESCE(debut_seance, lower(creneau), lower(fenetre))
                    FROM occurrence WHERE id_occurrence = %(o)s""", o=o)
    minute = 0
    for ligne in exercices:
        code, series = ligne["code"], ligne["series"]
        depart, pas = CHARGES.get(code, (20, 1))
        for n in range(1, series + 1):
            minute += 3
            if code == "planche":
                charge, reps, duree = None, None, 45 + 5 * rang
            else:
                charge = (depart + pas * rang) or None
                reps = ligne["repetitions_max"] - (1 if n == series else 0)
                duree = None
            sql("""SELECT enregistrer_serie(%(u)s::INTEGER, %(o)s::INTEGER, %(e)s::INTEGER,
                                            %(k)s, %(n)s::INTEGER, %(c)s::NUMERIC,
                                            %(r)s::INTEGER, %(d)s::INTEGER, NULL,
                                            %(m)s::INTEGER, %(q)s)""",
                u=u, o=o, e=exo(code), k=uuid.uuid4(), n=n, c=charge, r=reps, d=duree,
                m=1 if n < series else 0, q=debut + timedelta(minutes=minute))
    sql("SELECT enregistrer_bilan(%(u)s, %(o)s, %(e)s, %(d)s, %(c)s, %(k)s)",
        u=u, o=o, e=effort, d=minute + 8, c=commentaire, k=uuid.uuid4())


def course_de_la_montre(u: int, cle: str, debut: datetime, minutes: int, km: float,
                        fc: int, discipline="course") -> None:
    secondes = minutes * 60
    allure = int(secondes / km) if km else None
    donnees = {"duree_secondes": secondes, "distance_m": int(km * 1000),
               "denivele_m": 42, "energie_kcal": int(minutes * 11), "fc_moyenne": fc,
               "fc_max": fc + 22, "allure_s_km": allure, "cadence": 168,
               "details": {"kilometres": [allure + d for d in (12, 4, -3, 0, -8, 6)][:int(km)],
                           "zones": [4, 18, 52, 22, 4]}}
    sql("""SELECT recevoir_activite(%(u)s, %(k)s, %(t)s, %(d)s, %(a)s, %(b)s,
                                    %(j)s::JSONB)""",
        u=u, k=cle, t="running" if discipline == "course" else "walking", d=discipline,
        a=debut, b=debut + timedelta(seconds=secondes),
        j=json.dumps(donnees))


def echange(u: int, auteur: str, moment: str, texte: str, quand: datetime,
            op: str | None = None, occurrence: int | None = None, importance: int = 2) -> None:
    elements = reponse.elements_de(op) if op else []
    sql("""INSERT INTO echange (id_utilisateur, quand, auteur, moment, contenu, id_occurrence,
                                operation, modele, version_dossier, elements)
           VALUES (%(u)s, %(q)s, %(a)s, %(m)s, %(c)s, %(o)s, %(op)s, %(mo)s, %(v)s, %(e)s)""",
        u=u, q=quand, a=auteur, m=moment, c=texte, o=occurrence, op=op,
        mo=MODELE if auteur == "coach" else None,
        v=dossier.version() if auteur == "coach" else None, e=Jsonb(elements))
    if auteur == "coach":
        sql("""INSERT INTO notification (id_utilisateur, type, contenu, statut, date_envoi,
                                         id_echange)
               SELECT %(u)s, 'coach', left(%(c)s, 200), 'envoyee', %(q)s, max(id_echange)
                 FROM echange WHERE id_utilisateur = %(u)s""", u=u, c=texte, q=quand)


def sport(t: int, lo: int) -> None:
    sql("""INSERT INTO profil (id_utilisateur, date_naissance, sexe, taille_cm,
                               niveau_musculation, niveau_course)
           VALUES (%(u)s, '2001-03-12', 'homme', 181, 'intermediaire', 'debutant')""", u=t)
    sql("""INSERT INTO depistage (id_utilisateur, coeur, vertiges, maladie_chronique, traitement,
                                  os_articulations, grossesse, sedentaire_age)
           VALUES (%(u)s, false, false, false, false, false, false, false)""", u=t)
    sql("""INSERT INTO discipline_lieu VALUES (%(u)s, 'musculation', %(s)s, 1),
                                              (%(u)s, 'course', %(c)s, 1),
                                              (%(u)s, 'cardio', %(s)s, 1)""",
        u=t, s=lieu("SALLE"), c=lieu("COURSE"))
    sql("""INSERT INTO objectif (id_utilisateur, type, libelle, distance_m, cible_valeur,
                                 cible_unite, echeance, principal, rang, avis, avis_detail,
                                 feuille_de_route, date_creation)
           VALUES (%(u)s, 'course', '10 km en moins de 50 minutes', 10000, 50, 'min',
                   %(e)s, TRUE, 1, 'ambitieux', %(avis)s, %(route)s, %(c)s)""",
        u=t, e=J + timedelta(days=74), c=J - timedelta(days=21),
        avis="Faisable en dix semaines si les trois séances tiennent. "
             "Le seuil est le point faible.",
        route="Semaines 1 à 4 : asseoir l'endurance. 5 à 8 : seuil et fractionné. "
              "9 et 10 : affûtage.")
    sql("""INSERT INTO objectif (id_utilisateur, type, libelle, pilier, principal, rang)
           VALUES (%(u)s, 'pilier', 'Garder la force du haut du corps', 'force', FALSE, 2)""",
        u=t)
    sql("SELECT activer_coach(%(u)s)", u=t)
    sql("""INSERT INTO demarrage_coach (id_utilisateur, etape, reponses)
           VALUES (%(u)s, 'fini', '{"_limitations_faites": true}')""", u=t)
    sql("""INSERT INTO limitation (id_utilisateur, libelle, zone, cote, description)
           VALUES (%(u)s, 'Épaule qui accroche', 'epaule', 'droite',
                   'Pas de développé derrière la nuque')""", u=t)

    # Avant le plan, trois semaines de séances libres et de courses de la
    # montre : de quoi tracer une progression.
    rang = 0
    for decalage, quoi in ((-24, "haut"), (-22, "course"), (-20, "bas"), (-18, "course"),
                           (-17, "haut"), (-15, "course"), (-13, "bas"), (-11, "course"),
                           (-10, "haut"), (-8, "course"), (-6, "bas")):
        jour = J + timedelta(days=decalage)
        if quoi == "course":
            course_de_la_montre(t, f"maquette-course{decalage}", a(jour, 12, 30),
                                40 - decalage // 6, 6, 150 - decalage // 4)
            continue
        rang += 1
        libre = un("""SELECT creer_seance_libre(%(u)s, 'musculation', %(d)s, 60, NULL, FALSE,
                                                %(k)s, 'libre')""",
                   u=t, d=a(jour, 18, 30), k=uuid.uuid4())
        faire_muscu(t, libre, HAUT if quoi == "haut" else BAS, rang, 7,
                    "Séance correcte, un peu fatigué.")

    # Le plan : quatre semaines à partir de ce lundi.
    with operation.ouvrir("fausse base : plan", acteur="hal") as op:
        sql("""SELECT construire_plan(%(u)s, %(l)s, 'Endurance d''abord, puis le seuil',
                                      ARRAY['charge', 'charge', 'charge', 'allegee'])""",
            u=t, l=LUNDI)
    echange(t, "utilisateur", "plan", "C'est bon pour moi, on peut lancer le plan.",
            a(LUNDI - timedelta(days=1), 21, 2))
    echange(t, "coach", "plan",
            "Voilà ton plan sur quatre semaines. Trois à quatre séances par semaine : deux de "
            "course, une ou deux de musculation, et une semaine plus légère à la fin.",
            a(LUNDI - timedelta(days=1), 21, 3), op=op.identifiant)

    # Les séances de cette semaine déjà passées, faites.
    passees = []
    for jour in (LUNDI + timedelta(days=k) for k in range((J - LUNDI).days)):
        quoi = ("haut", "course", "course_frac", "bas", "course", "haut", "course")[jour.weekday()]
        if quoi == "haut":
            o = proposer_valider(t, "musculation", "Haut du corps", jour, HAUT)
        elif quoi == "bas":
            o = proposer_valider(t, "musculation", "Bas du corps", jour, BAS)
        elif quoi == "course":
            o = proposer_valider(t, "course", "Endurance fondamentale", jour, COURSE_EF,
                                 intensite="legere", duree=45, plage=("12:00", "14:00"))
        else:
            o = proposer_valider(t, "course", "Fractionné court", jour, COURSE_FRAC,
                                 intensite="dure", duree=45, plage=("12:00", "14:00"))
        passees.append((o, quoi))

    for o, quoi in passees:
        debut = un("SELECT debut_seance FROM occurrence WHERE id_occurrence = %(o)s", o=o)
        if quoi in ("haut", "bas"):
            rang += 1
            faire_muscu(t, o, HAUT if quoi == "haut" else BAS, rang, 8,
                        "Bonnes sensations, le dernier développé était dur.")
        else:
            km = 6 if quoi == "course" else 7
            course_de_la_montre(t, f"maquette-course-{o}", debut, 41 if km == 6 else 44,
                                km, 152 if quoi == "course" else 164)

    derniere = next((o for o, quoi in reversed(passees) if quoi in ("haut", "bas")), None)
    echange(t, "coach", "bilan",
            "Belle séance. Tu as gagné 2,5 kg au développé couché en trois semaines, et ta "
            "dernière série tient les 6 répétitions. On garde la même charge ce soir.",
            a(J - timedelta(days=2), 20, 15), occurrence=derniere)

    # Une séance libre, faite il y a trois jours (LIB-2) : les exercices
    # s'ajoutent en saisissant leurs séries.
    libre = un("""SELECT creer_seance_libre(%(u)s, 'musculation', %(d)s, 40, NULL, FALSE,
                                            %(k)s, 'libre')""",
               u=t, d=a(J - timedelta(days=3), 19), k=uuid.uuid4())
    for code, charge, reps in (("pompes", None, 15), ("curl_halteres", 12, 12)):
        for n in range(1, 4):
            sql("""SELECT enregistrer_serie(%(u)s::INTEGER, %(o)s::INTEGER, %(e)s::INTEGER,
                                            %(k)s, %(n)s::INTEGER, %(c)s::NUMERIC,
                                            %(r)s::INTEGER, NULL, NULL, 1, %(q)s)""",
                u=t, o=libre, e=exo(code), k=uuid.uuid4(), n=n, c=charge, r=reps,
                q=a(J - timedelta(days=3), 19, 5 * n))
    sql("SELECT enregistrer_bilan(%(u)s, %(o)s, 6, 35, 'Vite fait à la maison.', %(k)s)",
        u=t, o=libre, k=uuid.uuid4())

    # Aujourd'hui : la musculation du soir, avec ses exercices (WID-6).
    proposer_valider(t, "musculation", "Haut du corps", J, HAUT, plage=("18:00", "21:00"),
                     consigne="Garde deux répétitions en réserve sur le développé.")

    # Demain midi, une course à envoyer à la montre, et un ajustement de HAL dessus.
    course = proposer(t, "course", "Endurance fondamentale", J + timedelta(days=1), COURSE_EF,
                      intensite="legere", duree=45, plage=("12:00", "14:00"))
    sql("SELECT valider_seance(%(u)s, %(o)s)", u=t, o=course)
    # Après-demain, la séance de test, et sa mesure qui la suit (MES-6).
    test = proposer(t, "course", "Test sur 5 km", J + timedelta(days=2), TEST,
                    intensite="dure", duree=50, plage=("12:00", "14:00"), test=True)
    sql("SELECT valider_seance(%(u)s, %(o)s)", u=t, o=test)
    # Le dimanche d'après, le bas du corps, avec une invitation pour Lorette
    # (SPT-31) : elle ne travaille pas ce jour-là.
    dimanche = J + timedelta(days=3)
    while dimanche.weekday() != 6:
        dimanche += timedelta(days=1)
    bas = proposer(t, "musculation", "Bas du corps", dimanche, BAS, plage=("10:00", "13:00"))
    sql("SELECT valider_seance(%(u)s, %(o)s)", u=t, o=bas)
    n = un("SELECT inviter_a_la_seance(%(o)s)", o=bas)
    dire(f"séances : {len(passees)} faites cette semaine, des libres avant, aujourd'hui, "
         f"demain, un test, le bas du corps ({n} invitation)")

    with operation.ouvrir("fausse base : ajustement", acteur="hal") as op:
        sql("""SELECT proposer_ajustement(%(u)s, %(o)s, 'alleger',
                                          '{"duree_minutes": 35, "intensite": "legere"}',
                                          %(m)s)""",
            u=t, o=course,
            m="Ta variabilité cardiaque est basse depuis trois jours et ta nuit a été courte.")
    echange(t, "coach", "revision",
            "Ta nuit a été courte et ta VFC baisse depuis trois jours. Je propose d'alléger "
            "la course de demain : 35 minutes, tout en aisance.",
            a(J, 7, 40), op=op.identifiant, occurrence=course, importance=3)

    with operation.ouvrir("fausse base : test", acteur="hal") as op:
        sql("""SELECT ouvrir_fenetre_mesure(%(u)s, 'test_course', %(d)s, %(f)s,
                                            %(c)s)""",
            u=t, d=J + timedelta(days=2), f=J + timedelta(days=4),
            c="Note ton temps sur 5 km, montre arrêtée à la ligne.")
    with operation.ouvrir("fausse base : poids", acteur="hal") as op:
        sql("""SELECT ouvrir_fenetre_mesure(%(u)s, 'poids', %(d)s, %(f)s,
                                            'Le matin, à jeun, après être passé aux toilettes.')""",
            u=t, d=J - timedelta(days=1), f=J + timedelta(days=3))
    echange(t, "coach", "synthese",
            "Récap d'hier : course faite, 6 km à 6'50 au kilomètre, FC moyenne 152. "
            "Ce soir, le haut du corps. Pense à te peser cette semaine.",
            a(J - timedelta(days=1), 23, 0), op=op.identifiant)

    # La semaine prochaine : proposée, à valider (PLN-6).
    lundi = LUNDI + timedelta(days=7)
    with operation.ouvrir("fausse base : semaine", acteur="hal") as op:
        for decalage, quoi in ((0, "course"), (2, "haut"), (3, "bas"), (4, "course_frac")):
            jour = lundi + timedelta(days=decalage)
            if quoi == "haut":
                proposer(t, "musculation", "Haut du corps", jour, HAUT)
            elif quoi == "bas":
                proposer(t, "musculation", "Bas du corps", jour, BAS, plage=("18:00", "21:00"))
            elif quoi == "course":
                proposer(t, "course", "Endurance fondamentale", jour, COURSE_EF,
                         intensite="legere", duree=45, plage=("12:00", "14:00"))
            else:
                proposer(t, "course", "Fractionné court", jour, COURSE_FRAC,
                         intensite="dure", duree=45, plage=("12:00", "14:00"))
    echange(t, "utilisateur", "chat", "Tu peux me préparer la semaine prochaine ?",
            a(J, 8, 10))
    echange(t, "coach", "chat",
            "Voici la semaine prochaine : deux courses, dont un fractionné vendredi, et deux "
            "séances de musculation. Valide-la si elle te convient.",
            a(J, 8, 11), op=op.identifiant)
    dire("plan sur quatre semaines, ajustement, deux fenêtres de mesure, semaine à valider")


def sante(t: int) -> None:
    for k in range(30, 0, -1):
        jour = J - timedelta(days=k)
        vague = math.sin(k / 3.0)
        sql("SELECT recevoir_sante_jour(%(u)s::INTEGER, %(j)s, %(p)s::INTEGER, %(f)s::INTEGER, "
            "%(v)s::NUMERIC, %(s)s::INTEGER)",
            u=t, j=jour, p=int(8200 + 2600 * vague + (k % 5) * 310),
            f=int(55 + 2 * vague + (3 if k <= 3 else 0)),
            v=round(58 + 7 * vague - (9 if k <= 3 else 0), 1),
            s=int(445 + 35 * vague - (70 if k == 1 else 0)))
    # Aujourd'hui, la nuit et les pas du matin seulement.
    sql("SELECT recevoir_sante_jour(%(u)s::INTEGER, %(j)s, 2140, 58, 49.5, 372)", u=t, j=J)

    # Une marche hors plan, venue de la montre.
    course_de_la_montre(t, "maquette-marche", a(J - timedelta(days=6), 17, 30), 52, 4.2, 104,
                        discipline="autre")

    for k, poids in ((49, 76.8), (42, 76.4), (35, 76.1), (28, 75.9), (21, 75.4), (14, 75.6),
                     (7, 75.1)):
        sql("SELECT saisir_mesure(%(u)s::INTEGER, 'poids', %(v)s::NUMERIC, 'kg', NULL, %(d)s)",
            u=t, v=poids, d=J - timedelta(days=k))
    for k, tour in ((42, 84.0), (21, 83.0), (7, 82.5)):
        sql("SELECT saisir_mesure(%(u)s::INTEGER, 'tour_taille', %(v)s::NUMERIC, 'cm', NULL, "
            "%(d)s)",
            u=t, v=tour, d=J - timedelta(days=k))
    for k, bras in ((42, 34.0), (7, 34.5)):
        sql("SELECT saisir_mesure(%(u)s::INTEGER, 'tour_bras', %(v)s::NUMERIC, 'cm', 'droite', "
            "%(d)s)",
            u=t, v=bras, d=J - timedelta(days=k))
    dire("trente jours de santé, une marche de la montre, des mesures")


def principal() -> None:
    base = configuration().postgres_db
    if base != "planif_maquette":
        raise SystemExit(f"Base visée : {base}. Ce script ne remplit que planif_maquette.")
    with operation.ouvrir("fausse base", acteur="maquette"):
        t, lo = comptes()
        planning(t, lo)
        maison(t, lo)
    sport(t, lo)
    sante(t)
    print()
    for pseudo, mdp in MOTS_DE_PASSE.items():
        print(f"  {pseudo:8} {mdp}")


if __name__ == "__main__":
    principal()
