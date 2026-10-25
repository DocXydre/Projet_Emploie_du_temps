"""Le module coach.

Deux moitiés. La première vérifie ce que la base tient : le placement d'une
séance, les trois règles de sécurité, la validation, les ajustements, la
saisie, la santé, la pause. La seconde vérifie la boucle : un appel au coach,
ses outils par moment, sa réponse à forme fixe, ses échecs.

Aucun appel payant : le modèle est remplacé par un faux, qui joue un scénario
écrit tour par tour. Les règles tenues par le vrai modèle se vérifient à part,
avec les scénarios de `coach/scenarios/`.
"""

import json
import uuid
from datetime import date, datetime, timedelta

import psycopg
import pytest

from api.coach import appel, contexte, dossier, modele, outils, planifie, reponse
from api.coach import telegram as coach_tg
from api.coach.clair import aujourd_hui, lundi_de
from api.config import configuration
from api.ordonnanceur import placer
from tests.test_ensemble import PARIS, _id, sql, un


def jour_de_paris(moment):
    return moment.astimezone(PARIS).date()


EXOS_HAUT = [{"code": "presse_pectoraux", "series": 3, "repetitions_min": 8,
              "repetitions_max": 12},
             {"code": "rowing_assis_machine", "series": 3, "repetitions_min": 8,
              "repetitions_max": 12}]


# ---------------------------------------------------------------------------
# De quoi préparer un compte
# ---------------------------------------------------------------------------

def lieu(code: str) -> int:
    return un("SELECT id_lieu FROM lieu_sport WHERE code = %s", code)


def exo(code: str) -> int:
    return un("SELECT id_exercice FROM exercice WHERE code = %s", code)


def refus(requete: str, *parametres) -> str:
    """Le code stable du refus que la base oppose à cette requête."""
    with pytest.raises(psycopg.Error) as erreur:
        sql(requete, *parametres)
    assert erreur.value.diag.table_name == "coach", erreur.value
    return erreur.value.diag.constraint_name


def jour(dans: int) -> date:
    return aujourd_hui() + timedelta(days=dans)


@pytest.fixture
def u(base) -> int:
    """Thomas, avec tout ce qu'il faut pour un premier plan, coach activé."""
    u = _id("thomas")
    sql("INSERT INTO profil (id_utilisateur, date_naissance, sexe, taille_cm, "
        "niveau_musculation, niveau_course) VALUES (%s, '2000-01-01', 'homme', 180, "
        "'intermediaire', 'debutant')", u)
    sql("INSERT INTO depistage (id_utilisateur, coeur, vertiges, maladie_chronique, "
        "traitement, os_articulations, grossesse, sedentaire_age) "
        "VALUES (%s, false, false, false, false, false, false, false)", u)
    sql("INSERT INTO discipline_lieu VALUES (%s, 'musculation', %s, 1), "
        "(%s, 'course', %s, 1), (%s, 'cardio', %s, 1)",
        u, lieu("SALLE"), u, lieu("COURSE"), u, lieu("SALLE"))
    sql("INSERT INTO objectif (id_utilisateur, type, libelle, pilier, principal) "
        "VALUES (%s, 'pilier', 'Prendre du muscle', 'physique', true)", u)
    sql("SELECT activer_coach(%s)", u)
    # Le démarrage est fini : la question des limitations a été posée (DEM-3).
    sql("INSERT INTO demarrage_coach (id_utilisateur, etape, reponses) "
        "VALUES (%s, 'fini', '{\"_limitations_faites\": true}')", u)
    return u


@pytest.fixture
def plan(u) -> int:
    rendu = un("SELECT construire_plan(%s, lundi_de(jour_de(now())), 'Trame du mois', "
               "ARRAY['charge', 'charge', 'charge', 'allegee'])", u)
    return rendu["id_plan"]


def proposer(u: int, dans: int = 3, discipline: str = "musculation",
             intensite: str = "moderee", exercices=EXOS_HAUT, groupes=None,
             duree: int = 60, plage=("09:00", "22:00"), cle: bool = False) -> int:
    return un(
        "SELECT proposer_seance(%s, %s, 'séance', %s, %s, %s, %s::TIME, %s::TIME, NULL, "
        "%s, FALSE, %s::TEXT[], NULL, %s::JSONB)",
        u, discipline, intensite, duree, jour(dans), plage[0], plage[1], cle, groupes,
        json.dumps(exercices) if exercices else None)


def reculer(id_occurrence: int, heures: float = 3) -> None:
    """Fait comme si la séance avait eu lieu il y a quelques heures."""
    debut = datetime.now(PARIS) - timedelta(hours=heures)
    sql("UPDATE occurrence SET debut_seance = %s, "
        "creneau = tstzrange(%s, %s::TIMESTAMPTZ + INTERVAL '1 hour', '[)'), "
        "fenetre = tstzrange(%s::TIMESTAMPTZ - INTERVAL '1 day', "
        "                    %s::TIMESTAMPTZ + INTERVAL '2 days', '[)') "
        "WHERE id_occurrence = %s", debut, debut, debut, debut, debut, id_occurrence)


# ---------------------------------------------------------------------------
# Le dossier                                                           (COA-8)
# ---------------------------------------------------------------------------

def test_le_dossier_a_un_fichier_par_chapitre():
    assert len(dossier.chapitres()) == 49
    assert set(dossier.socle()) <= set(dossier.chapitres())
    assert dossier.chapitre("4.5").startswith("# 4.5 ")
    assert dossier.chapitre("../../.env") is None


def test_le_dossier_ne_nomme_personne():
    # Le dépôt est public, et le dossier part dans les appels de tous les comptes.
    texte = (dossier.base() + "".join(dossier.chapitres().values())).lower()
    for mot in ("thomas", "lorette", "lusse", "saint-dié"):
        assert mot not in texte, mot


def test_la_partie_fixe_de_la_consigne_ne_change_pas_d_un_appel_a_l_autre(u):
    premier = appel.consigne(u)[0]["text"]
    assert appel.consigne(u)[0]["text"] == premier
    assert premier.startswith("# Ton cadre de travail")
    assert "# 1.2 Sécurité" in premier and "# 10.3" in premier
    # Le contexte, lui, vient après et parle de l'utilisateur.
    assert "Prendre du muscle" in appel.consigne(u)[2]["text"]


def test_le_contexte_porte_la_fiche_de_la_limitation(u):
    limitation = un("INSERT INTO limitation (id_utilisateur, libelle, zone, cote, "
                    "description) VALUES (%s, 'Rotation limitée', 'avant-bras', 'gauche', "
                    "'Jamais paume vers le haut à gauche') RETURNING id_limitation", u)
    sql("INSERT INTO exercice_interdit VALUES (%s, %s, 'paume vers le haut')",
        limitation, exo("curl_barre"))

    contexte = appel.consigne(u)[2]["text"]

    assert "Jamais paume vers le haut à gauche" in contexte
    assert "curl_barre" in contexte


def test_le_contexte_d_un_compte_ne_contient_rien_d_un_autre(u):
    # Scénario de sécurité du chapitre 10.5 : un compte ne reçoit jamais un
    # élément de la fiche d'un autre.
    lorette = _id("lorette")
    sql("INSERT INTO limitation (id_utilisateur, libelle, zone, cote, description) "
        "VALUES (%s, 'Genou fragile', 'genou', 'droite', 'SECRET-DE-LORETTE')", lorette)
    sql("INSERT INTO memoire_coach (id_utilisateur, niveau, texte, auteur) "
        "VALUES (%s, 'globale', 'NOTE-DE-LORETTE', 'utilisateur')", lorette)

    contexte = appel.consigne(u)[2]["text"]

    assert "SECRET-DE-LORETTE" not in contexte and "NOTE-DE-LORETTE" not in contexte


# ---------------------------------------------------------------------------
# Le plan                                              (PLN-1, OBJ-8, PRO-4 à 6)
# ---------------------------------------------------------------------------

PLAN = ("SELECT construire_plan(%s, lundi_de(jour_de(now())), 'Trame', "
        "ARRAY['charge', 'charge', 'charge', 'allegee'])")


def test_pas_de_plan_sans_profil(base):
    thomas = _id("thomas")
    assert refus("SELECT activer_coach(%s)", thomas) == "profil_incomplet"


def test_le_depistage_ne_bloque_plus_le_plan(u):
    # Décision du 9 octobre : aucun questionnaire ni avis médical n'est exigé.
    sql("DELETE FROM depistage")
    assert un(PLAN, u)["id_plan"]


def test_pas_de_plan_sans_objectif_principal(u):
    sql("UPDATE objectif SET statut = 'en_pause'")
    assert refus(PLAN, u) == "objectif_requis"


def test_le_plan_rend_les_disciplines_sans_lieu(u):
    sql("DELETE FROM discipline_lieu WHERE discipline = 'course'")
    assert un(PLAN, u)["disciplines_sans_lieu"] == ["course"]


def test_un_plan_a_quatre_semaines_et_un_seul_est_en_cours(u, plan):
    assert un("SELECT count(*) FROM plan_semaine WHERE id_plan = %s", plan) == 4

    suivant = un(PLAN, u)["id_plan"]

    assert un("SELECT statut FROM plan WHERE id_plan = %s", plan) == "clos"
    assert un("SELECT count(*) FROM plan WHERE statut = 'en_cours'") == 1
    assert suivant != plan


def test_un_mineur_n_a_pas_de_coach(base):
    with pytest.raises(psycopg.errors.CheckViolation):
        sql("INSERT INTO profil (id_utilisateur, date_naissance, sexe, taille_cm, "
            "niveau_musculation, niveau_course) VALUES (%s, CURRENT_DATE - 6000, 'homme', "
            "170, 'debutant', 'debutant')", _id("lorette"))


def test_un_objectif_clos_ne_se_rouvre_pas(u):
    sql("UPDATE objectif SET statut = 'atteint', date_cloture = CURRENT_DATE")
    with pytest.raises(psycopg.Error) as erreur:
        sql("UPDATE objectif SET statut = 'actif'")
    assert erreur.value.diag.constraint_name == "objectif_clos"


# ---------------------------------------------------------------------------
# La proposition d'une séance                           (PLN-5, LIE-2, EXO-5)
# ---------------------------------------------------------------------------

def test_une_seance_proposee_occupe_son_creneau_sans_etre_epinglee(u, plan):
    seance = proposer(u)

    ligne = sql("SELECT origine, epinglee, statut, titre, creneau IS NOT NULL AS placee "
                "FROM occurrence WHERE id_occurrence = %s", seance)[0]

    assert ligne == {"origine": "coach", "epinglee": False, "statut": "planifiee",
                     "titre": "Musculation (à valider)", "placee": True}
    assert un("SELECT situation FROM v_seance_coach WHERE id_occurrence = %s",
              seance) == "proposee"


def test_les_groupes_viennent_des_exercices(u, plan):
    seance = proposer(u)
    assert sorted(un("SELECT groupes FROM seance WHERE id_occurrence = %s", seance)) == \
        ["dos", "pectoraux"]


def test_le_debut_est_choisi_dans_la_plage_du_coach(u, plan):
    seance = proposer(u, plage=("17:00", "19:00"))
    heure = un("SELECT (debut_seance AT TIME ZONE 'Europe/Paris')::TIME FROM occurrence "
               "WHERE id_occurrence = %s", seance)
    assert heure.hour in (17, 18) and (heure.hour, heure.minute) <= (18, 0)


def test_une_plage_plus_courte_que_la_seance_est_refusee(u, plan):
    assert refus("SELECT proposer_seance(%s, 'musculation', 's', 'moderee', 90, %s, "
                 "'18:00', '19:00', NULL, FALSE, FALSE, ARRAY['dos'])",
                 u, jour(3)) == "creneau_pris"


def test_une_seance_sur_un_cours_est_refusee_avec_son_motif(u, plan):
    debut = datetime.combine(jour(3), datetime.min.time(), tzinfo=PARIS).replace(hour=8)
    sql("INSERT INTO occupation (id_utilisateur, id_source, type, libelle, periode) "
        "VALUES (%s, (SELECT id_source FROM source WHERE code = 'MANUELLE'), 'cours', "
        "'Analyse', tstzrange(%s, %s, '[)'))",
        u, debut, debut + timedelta(hours=15))

    with pytest.raises(psycopg.Error) as erreur:
        proposer(u)

    assert erreur.value.diag.constraint_name == "creneau_pris"
    assert "Analyse" in erreur.value.diag.message_primary


def test_un_lieu_hors_de_la_discipline_est_refuse(u, plan):
    assert refus("SELECT proposer_seance(%s, 'course', 's', 'legere', 30, %s, '09:00', "
                 "'20:00', %s)", u, jour(3), lieu("PISCINE_SUAPS")) == "lieu_non_permis"


def test_un_exercice_inconnu_est_refuse(u, plan):
    with pytest.raises(psycopg.Error) as erreur:
        proposer(u, exercices=[{"code": "curl_du_dimanche"}])
    assert erreur.value.diag.constraint_name == "exercice_inconnu"


def test_un_exercice_desactive_est_refuse(u, plan):
    sql("UPDATE exercice SET actif = FALSE WHERE code = 'pec_deck'")
    try:
        with pytest.raises(psycopg.Error):
            proposer(u, exercices=[{"code": "pec_deck", "series": 3}])
    finally:
        sql("UPDATE exercice SET actif = TRUE WHERE code = 'pec_deck'")


def test_un_exercice_ne_se_supprime_pas(base):
    with pytest.raises(psycopg.errors.CheckViolation):
        sql("DELETE FROM exercice WHERE code = 'pec_deck'")


def test_hors_du_plan_rien_ne_se_propose(u, plan):
    with pytest.raises(psycopg.Error) as erreur:
        proposer(u, dans=40)
    assert erreur.value.diag.constraint_name == "hors_plan"


def test_le_maximum_de_la_semaine_est_tenu(u, plan):
    sql("UPDATE utilisateur SET seances_max_semaine = 1 WHERE id_utilisateur = %s", u)
    # Deux jours de la même semaine, quel que soit le jour où tourne le test.
    lundi_prochain = (lundi_de(aujourd_hui()) + timedelta(days=7) - aujourd_hui()).days
    proposer(u, dans=lundi_prochain)

    with pytest.raises(psycopg.Error) as erreur:
        proposer(u, dans=lundi_prochain + 2, discipline="course",
                 exercices=[{"code": "course_endurance", "duree_secondes": 1800}])

    assert erreur.value.diag.constraint_name == "maximum_semaine"


def test_deux_seances_par_jour_si_les_disciplines_different(u, plan):
    proposer(u, plage=("09:00", "12:00"))
    proposer(u, discipline="course", plage=("17:00", "21:00"),
             exercices=[{"code": "course_endurance", "duree_secondes": 1800}], duree=30)

    with pytest.raises(psycopg.Error) as erreur:
        proposer(u, plage=("13:00", "16:00"))

    assert "déjà prévue" in erreur.value.diag.message_primary


def test_une_esquisse_dit_ses_groupes(u, plan):
    assert refus("SELECT proposer_seance(%s, 'musculation', 's', 'dure', 60, %s, '09:00', "
                 "'20:00')", u, jour(3)) == "requete_invalide"

    esquisse = proposer(u, exercices=None, groupes=["quadriceps", "fessiers"])

    assert un("SELECT situation FROM v_seance_coach WHERE id_occurrence = %s",
              esquisse) == "esquisse"


def test_pas_de_charge_fixee_en_semaine_de_calibrage(u, plan):
    sql("UPDATE plan_semaine SET role = 'calibrage'")
    avec_charge = [{"code": "presse_pectoraux", "series": 3, "charge_kg": 40}]
    with pytest.raises(psycopg.Error) as erreur:
        proposer(u, exercices=avec_charge)
    assert erreur.value.diag.constraint_name == "charge_non_permise"


def test_pas_de_charge_sur_un_exercice_jamais_saisi(u, plan):
    avec_charge = [{"code": "presse_pectoraux", "series": 3, "charge_kg": 40}]
    with pytest.raises(psycopg.Error) as erreur:
        proposer(u, exercices=avec_charge)
    assert erreur.value.diag.constraint_name == "charge_non_permise"

    # Une fois l'exercice saisi, ce qui a été saisi devient la référence.
    libre = un("SELECT creer_seance_libre(%s, 'musculation', now() - INTERVAL '1 hour')", u)
    sql("SELECT enregistrer_serie(%s, %s, %s, %s, 1, 40, 10)",
        u, libre, exo("presse_pectoraux"), uuid.uuid4())

    assert proposer(u, exercices=avec_charge)


def test_le_menage_ne_deplace_pas_une_seance_proposee(u, plan):
    seance = proposer(u, dans=10)
    avant = un("SELECT creneau FROM occurrence WHERE id_occurrence = %s", seance)

    placer()

    apres = sql("SELECT creneau, statut FROM occurrence WHERE id_occurrence = %s", seance)[0]
    assert apres == {"creneau": avant, "statut": "planifiee"}


def test_un_compte_avec_coach_n_a_plus_de_reservations(u, plan):
    placer()
    assert un("SELECT count(*) FROM occurrence WHERE id_utilisateur = %s "
              "AND origine = 'quota'", u) == 0


# ---------------------------------------------------------------------------
# Les règles de sécurité                                        (SEC-1 à SEC-4)
# ---------------------------------------------------------------------------

@pytest.fixture
def limitation(u) -> int:
    limitation = un("INSERT INTO limitation (id_utilisateur, libelle, zone, cote, "
                    "description) VALUES (%s, 'Rotation limitée', 'avant-bras', 'gauche', "
                    "'Fiche') RETURNING id_limitation", u)
    sql("INSERT INTO exercice_interdit VALUES (%s, %s, 'paume vers le haut')",
        limitation, exo("curl_barre"))
    return limitation


def test_un_exercice_interdit_est_refuse_dans_une_proposition(u, plan, limitation):
    with pytest.raises(psycopg.Error) as erreur:
        proposer(u, exercices=[{"code": "curl_barre", "series": 3}])

    assert erreur.value.diag.constraint_name == "exercice_interdit"
    assert "paume vers le haut" in erreur.value.diag.message_primary


def test_un_exercice_interdit_est_refuse_a_la_saisie_meme_en_seance_libre(u, limitation):
    libre = un("SELECT creer_seance_libre(%s, 'musculation', now() - INTERVAL '1 hour')", u)

    assert refus("SELECT enregistrer_serie(%s, %s, %s, %s, 1, 20, 10)",
                 u, libre, exo("curl_barre"), uuid.uuid4()) == "exercice_interdit"


def test_une_limitation_desactivee_n_interdit_plus(u, plan, limitation):
    sql("UPDATE limitation SET active = FALSE")
    assert proposer(u, exercices=[{"code": "curl_barre", "series": 3}])


def test_la_limitation_d_un_compte_n_interdit_rien_a_l_autre(u, plan, limitation):
    sql("UPDATE limitation SET id_utilisateur = %s", _id("lorette"))
    assert proposer(u, exercices=[{"code": "curl_barre", "series": 3}])


def test_il_n_existe_qu_une_charge_pour_les_deux_cotes(base):
    # SEC-2 : une différence entre les deux bras est impossible à écrire.
    colonnes = sql("SELECT table_name, column_name FROM information_schema.columns "
                   "WHERE table_name IN ('seance_exercice', 'serie_saisie')")
    for colonne in colonnes:
        assert "gauche" not in colonne["column_name"]
        assert "droite" not in colonne["column_name"]
        assert colonne["column_name"] != "cote"


def test_deux_seances_dures_d_un_meme_groupe_ne_se_collent_pas(u, plan):
    proposer(u, dans=3, intensite="dure", plage=("18:00", "20:00"))

    with pytest.raises(psycopg.Error) as erreur:
        proposer(u, dans=4, intensite="dure", plage=("09:00", "12:00"))

    assert erreur.value.diag.constraint_name == "seances_dures_collees"
    # D'autres groupes le lendemain, ou le même groupe en modéré : accepté.
    jambes = [{"code": "presse_cuisses", "series": 3}]
    assert proposer(u, dans=4, intensite="dure", exercices=jambes, plage=("09:00", "12:00"))
    assert proposer(u, dans=5, intensite="moderee", plage=("18:00", "21:00"))


def test_la_course_et_le_cardio_forment_un_seul_groupe(u, plan):
    proposer(u, dans=3, discipline="course", intensite="dure", duree=40,
             exercices=[{"code": "course_seuil", "duree_secondes": 1200}])

    with pytest.raises(psycopg.Error) as erreur:
        proposer(u, dans=4, discipline="cardio", intensite="dure", duree=30,
                 exercices=[{"code": "rameur_intervalles", "duree_secondes": 240}])

    assert erreur.value.diag.constraint_name == "seances_dures_collees"


def test_le_delai_entre_deux_seances_dures_est_un_reglage(u, plan):
    sql("UPDATE utilisateur SET repos_dur_heures = 12 WHERE id_utilisateur = %s", u)
    proposer(u, dans=3, intensite="dure", plage=("09:00", "11:00"))
    assert proposer(u, dans=4, intensite="dure", plage=("09:00", "11:00"))


def test_l_utilisateur_est_averti_mais_pas_empeche(u, plan):
    proposer(u, dans=3, intensite="dure", plage=("18:00", "20:00"))
    autre = proposer(u, dans=6, intensite="dure", plage=("09:00", "11:00"))
    debut = datetime.combine(jour(4), datetime.min.time(), tzinfo=PARIS).replace(hour=10)

    rendu = un("SELECT deplacer_seance(%s, %s, %s)", u, autre, debut)

    assert rendu["avertissements"][0]["code"] == "seances_dures_collees"
    assert un("SELECT jour_de(debut_seance) FROM occurrence WHERE id_occurrence = %s",
              autre) == jour(4)


# ---------------------------------------------------------------------------
# Validation et ajustements                              (PLN-6, PLN-7, PLN-18)
# ---------------------------------------------------------------------------

def _meme_semaine(nombre: int) -> list[int]:
    """Des écarts en jours qui tombent tous dans la semaine prochaine."""
    depart = (lundi_de(aujourd_hui()) + timedelta(days=7) - aujourd_hui()).days
    return [depart + 2 * i for i in range(nombre)]


def test_valider_la_semaine_epingle_ses_seances(u, plan):
    a, b = _meme_semaine(2)
    seance = proposer(u, dans=a)
    proposer(u, dans=b, discipline="course", duree=30,
             exercices=[{"code": "course_endurance", "duree_secondes": 1800}])

    validees = un("SELECT valider_semaine(%s, lundi_de(%s))", u, jour(a))

    assert validees == 2
    assert sql("SELECT epinglee, titre FROM occurrence WHERE id_occurrence = %s",
               seance)[0] == {"epinglee": True, "titre": "Musculation"}
    assert un("SELECT validee_le IS NOT NULL FROM plan_semaine WHERE lundi = lundi_de(%s)",
              jour(a))


def test_une_semaine_qui_garde_une_esquisse_ne_se_valide_pas(u, plan):
    a, b = _meme_semaine(2)
    proposer(u, dans=a)
    proposer(u, dans=b, exercices=None, groupes=["quadriceps"])

    assert refus("SELECT valider_semaine(%s, lundi_de(%s))", u, jour(a)) == \
        "seance_a_detailler"


def test_le_coach_ne_touche_plus_a_une_seance_validee(u, plan):
    seance = proposer(u)
    sql("SELECT valider_seance(%s, %s)", u, seance)

    assert refus("SELECT modifier_seance_proposee(%s, %s, %s)", u, seance,
                 json.dumps({"duree_minutes": 30})) == "seance_validee"
    assert refus("SELECT retirer_seance_proposee(%s, %s)", u, seance) == "seance_validee"


def test_detailler_une_esquisse(u, plan):
    esquisse = proposer(u, exercices=None, groupes=["pectoraux"])

    sql("SELECT modifier_seance_proposee(%s, %s, %s)", u, esquisse,
        json.dumps({"exercices": EXOS_HAUT}))

    ligne = sql("SELECT situation, exercices, groupes FROM v_seance_coach "
                "WHERE id_occurrence = %s", esquisse)[0]
    assert ligne["situation"] == "proposee" and ligne["exercices"] == 2
    assert sorted(ligne["groupes"]) == ["dos", "pectoraux"]


@pytest.fixture
def validee(u, plan) -> int:
    seance = proposer(u, intensite="dure")
    sql("SELECT valider_seance(%s, %s)", u, seance)
    return seance


def test_un_allegement_ne_peut_que_reduire(u, validee):
    for contenu in ({"duree_minutes": 90},
                    {"exercices": [{"code": "presse_pectoraux", "series": 5}]},
                    {"exercices": [{"code": "pec_deck", "series": 2}]}):
        assert refus("SELECT proposer_ajustement(%s, %s, 'alleger', %s, 'fatigue')",
                     u, validee, json.dumps(contenu)) == "requete_invalide", contenu


def test_un_ajustement_accepte_s_applique_et_la_seance_reste_validee(u, validee):
    ajustement = un(
        "SELECT proposer_ajustement(%s, %s, 'alleger', %s, 'nuit courte')", u, validee,
        json.dumps({"duree_minutes": 40, "intensite": "moderee",
                    "exercices": [{"code": "presse_pectoraux", "series": 2}]}))

    sql("SELECT accepter_ajustement(%s, %s)", u, ajustement)

    ligne = sql("SELECT duree_minutes, intensite, exercices, etat FROM v_seance_coach "
                "WHERE id_occurrence = %s", validee)[0]
    assert ligne == {"duree_minutes": 40, "intensite": "moderee", "exercices": 1,
                     "etat": "validee"}
    assert un("SELECT epinglee FROM occurrence WHERE id_occurrence = %s", validee)


def test_un_ajustement_refuse_ne_change_rien(u, validee):
    ajustement = un("SELECT proposer_ajustement(%s, %s, 'retirer', NULL, 'trop')",
                    u, validee)

    sql("SELECT refuser_ajustement(%s, %s)", u, ajustement)

    assert un("SELECT statut FROM occurrence WHERE id_occurrence = %s",
              validee) == "planifiee"


def test_une_seance_n_a_qu_un_ajustement_en_attente(u, validee):
    sql("SELECT proposer_ajustement(%s, %s, 'retirer', NULL, 'trop')", u, validee)
    assert refus("SELECT proposer_ajustement(%s, %s, 'retirer', NULL, 'encore')",
                 u, validee) == "requete_invalide"


def test_sans_reponse_le_silence_ne_peut_qu_alleger(u, plan):
    allegee = proposer(u, dans=3, intensite="dure")
    modifiee = proposer(u, dans=5, discipline="course", duree=40,
                        exercices=[{"code": "course_endurance", "duree_secondes": 2400}])
    for seance in (allegee, modifiee):
        sql("SELECT valider_seance(%s, %s)", u, seance)
    a = un("SELECT proposer_ajustement(%s, %s, 'alleger', %s, 'nuit courte')", u, allegee,
           json.dumps({"duree_minutes": 30}))
    m = un("SELECT proposer_ajustement(%s, %s, 'modifier', %s, 'autre idée')", u, modifiee,
           json.dumps({"type_seance": "fractionné"}))
    # Les deux séances commencent.
    sql("UPDATE occurrence SET debut_seance = now() - INTERVAL '1 minute' "
        "WHERE id_occurrence = ANY (%s)", [allegee, modifiee])

    sql("SELECT solder_ajustements()")

    assert un("SELECT statut FROM ajustement WHERE id_ajustement = %s", a) == "accepte"
    assert un("SELECT statut FROM ajustement WHERE id_ajustement = %s", m) == "caduc"
    assert un("SELECT duree_minutes FROM seance WHERE id_occurrence = %s", allegee) == 30
    assert un("SELECT type_seance FROM seance WHERE id_occurrence = %s", modifiee) == "séance"
    assert un("SELECT count(*) FROM notification WHERE type = 'coach'") == 1


# ---------------------------------------------------------------------------
# Saisie, bilan, séances libres                                     (SAI, LIB)
# ---------------------------------------------------------------------------

def test_la_meme_cle_ne_cree_pas_deux_series(u, validee):
    cle = uuid.uuid4()
    requete = "SELECT enregistrer_serie(%s, %s, %s, %s, NULL, 40, 10)"

    premier = un(requete, u, validee, exo("presse_pectoraux"), cle)
    second = un(requete, u, validee, exo("presse_pectoraux"), cle)

    assert (premier["etat"], second["etat"]) == ("creee", "existait")
    assert premier["id_serie"] == second["id_serie"]
    assert un("SELECT count(*) FROM serie_saisie") == 1


def test_une_serie_renseigne_ce_que_son_exercice_mesure(u, validee):
    assert refus("SELECT enregistrer_serie(%s, %s, %s, %s, 1, NULL, NULL, 60)",
                 u, validee, exo("presse_pectoraux"), uuid.uuid4()) == "requete_invalide"


def test_un_exercice_fait_a_la_place_d_un_autre_garde_le_lien(u, validee):
    prevue = un("SELECT id_seance_exercice FROM seance_exercice WHERE id_occurrence = %s "
                "AND id_exercice = %s", validee, exo("presse_pectoraux"))

    sql("SELECT enregistrer_serie(%s, %s, %s, %s, 1, 20, 12, NULL, NULL, NULL, NULL, %s)",
        u, validee, exo("developpe_couche_halteres"), uuid.uuid4(), prevue)

    detail = outils.detail_seance(u, validee)
    assert detail["saisi"][0]["en_remplacement"] is True


def test_une_serie_figee_ne_se_corrige_plus(u, validee):
    serie = un("SELECT enregistrer_serie(%s, %s, %s, %s, 1, 40, 10)",
               u, validee, exo("presse_pectoraux"), uuid.uuid4())["id_serie"]
    sql("SELECT figer_series(%s)", u)

    with pytest.raises(psycopg.Error) as erreur:
        sql("UPDATE serie_saisie SET charge_kg = 60 WHERE id_serie = %s", serie)
    assert erreur.value.diag.constraint_name == "serie_figee"
    # SAI-12 : une saisie qui arrive ensuite est acceptée.
    assert un("SELECT enregistrer_serie(%s, %s, %s, %s, 2, 40, 9)",
              u, validee, exo("presse_pectoraux"), uuid.uuid4())["etat"] == "creee"


def test_le_bilan_vaut_faite_et_donne_une_charge(u, validee):
    reculer(validee)

    sql("SELECT enregistrer_bilan(%s, %s, 7, 55, 'bien')", u, validee)

    ligne = sql("SELECT situation, charge, statut_occurrence FROM v_seance_coach "
                "WHERE id_occurrence = %s", validee)[0]
    assert ligne == {"situation": "faite", "charge": 385, "statut_occurrence": "faite"}


def test_une_seance_faite_sans_bilan_n_a_pas_de_charge(u, validee):
    reculer(validee)
    sql("SELECT enregistrer_serie(%s, %s, %s, %s, 1, 40, 10)",
        u, validee, exo("presse_pectoraux"), uuid.uuid4())
    sql("SELECT clore_seances_du_jour(%s)", u)

    charge = sql("SELECT charge_7j, seances_sans_bilan_28j FROM v_charge_entrainement "
                 "WHERE id_utilisateur = %s", u)[0]

    # Une donnée absente, pas un zéro qui ferait croire à une séance sans effort.
    assert un("SELECT charge FROM v_seance_coach WHERE id_occurrence = %s", validee) is None
    assert charge["seances_sans_bilan_28j"] == 1
    assert charge["charge_7j"] is None


def test_a_23h_une_seance_est_faite_ou_pas_faite(u, plan):
    faite = proposer(u, dans=3)
    oubliee = proposer(u, dans=5, discipline="course", duree=30,
                       exercices=[{"code": "course_endurance", "duree_secondes": 1800}])
    a_venir = proposer(u, dans=7)
    reculer(faite, 5)
    reculer(oubliee, 3)
    sql("SELECT enregistrer_serie(%s, %s, %s, %s, 1, 40, 10)",
        u, faite, exo("presse_pectoraux"), uuid.uuid4())

    rendu = un("SELECT clore_seances_du_jour(%s)", u)

    # Proposée ou validée, c'est pareil : ne pas valider n'excuse pas de ne rien faire.
    assert rendu["faites"] == [faite] and rendu["pas_faites"] == [oubliee]
    assert un("SELECT statut FROM occurrence WHERE id_occurrence = %s", a_venir) == "planifiee"
    assert un("SELECT situation FROM v_seance_coach WHERE id_occurrence = %s",
              oubliee) == "pas_faite"


def test_une_seance_libre_remplace_la_seance_prevue_de_meme_discipline(u, plan):
    prevue = proposer(u, dans=3)
    course = proposer(u, dans=3, discipline="course", duree=30, plage=("17:00", "21:00"),
                      exercices=[{"code": "course_endurance", "duree_secondes": 1800}])
    # La séance libre deux heures plus tôt, et la prévue une heure après elle :
    # le même jour à Paris, même juste après minuit.
    maintenant = datetime.now(PARIS)
    debut = max(maintenant - timedelta(hours=2),
                maintenant.replace(hour=0, minute=0, second=0, microsecond=0))
    reculer(prevue, (maintenant - debut) / timedelta(hours=1) - 1)
    sql("UPDATE occurrence SET debut_seance = now() + INTERVAL '2 hours', "
        "creneau = tstzrange(now() + INTERVAL '2 hours', now() + INTERVAL '3 hours'), "
        "fenetre = tstzrange(now() - INTERVAL '1 day', now() + INTERVAL '1 day') "
        "WHERE id_occurrence = %s", course)
    libre = un("SELECT creer_seance_libre(%s, 'musculation', %s, 50, NULL, FALSE, %s)",
               u, debut, uuid.uuid4())
    sql("SELECT enregistrer_serie(%s, %s, %s, %s, 1, 14, 12)",
        u, libre, exo("curl_marteau"), uuid.uuid4())

    rendu = un("SELECT enregistrer_bilan(%s, %s, 8, 50)", u, libre)

    assert rendu["remplacee"] == prevue
    assert un("SELECT situation FROM v_seance_coach WHERE id_occurrence = %s",
              prevue) == "remplacee"
    # LIB-12 : effort 8, donc dure. Les groupes sont ceux des exercices saisis.
    assert sql("SELECT intensite, groupes, libre FROM seance WHERE id_occurrence = %s",
               libre)[0] == {"intensite": "dure", "groupes": ["biceps"], "libre": True}
    # D'une autre discipline, la séance prévue reste : les deux se font.
    assert un("SELECT statut FROM occurrence WHERE id_occurrence = %s", course) == "planifiee"


def test_faire_autre_chose_garde_le_creneau_et_vide_le_contenu(u, validee):
    avant = un("SELECT creneau FROM occurrence WHERE id_occurrence = %s", validee)

    sql("SELECT liberer_seance(%s, %s)", u, validee)

    ligne = sql("SELECT libre, auteur, exercices FROM v_seance_coach "
                "WHERE id_occurrence = %s", validee)[0]
    assert ligne == {"libre": True, "auteur": "utilisateur", "exercices": 0}
    assert un("SELECT creneau FROM occurrence WHERE id_occurrence = %s", validee) == avant


def test_la_meme_cle_rend_la_meme_seance_libre(u):
    cle = uuid.uuid4()
    requete = "SELECT creer_seance_libre(%s, 'course', now(), 40, NULL, FALSE, %s)"
    assert un(requete, u, cle) == un(requete, u, cle)


# ---------------------------------------------------------------------------
# Données de santé et mesures                                       (SAN, MES)
# ---------------------------------------------------------------------------

def test_un_envoi_repete_ne_duplique_rien_et_un_envoi_partiel_ne_perd_rien(u):
    sql("SELECT recevoir_sante_jour(%s, jour_de(now()), 9000, 54, 61.5, 430)", u)
    sql("SELECT recevoir_sante_jour(%s, jour_de(now()), 11000)", u)

    assert sql("SELECT pas, fc_repos, sommeil_minutes FROM sante_jour") == \
        [{"pas": 11000, "fc_repos": 54, "sommeil_minutes": 430}]


def test_une_donnee_absente_n_est_pas_un_zero(u):
    sql("SELECT recevoir_sante_jour(%s, jour_de(now()), NULL, NULL, NULL, 420)", u)

    assert un("SELECT pas FROM sante_jour") is None
    debut = (aujourd_hui() - timedelta(days=6)).isoformat()
    rendu = outils.lire_sante(u, {"du": debut, "detail": True})
    assert "pas" not in rendu["jours"][0]
    assert "pas" not in rendu["moyennes_7_derniers_jours"]
    assert rendu["jours_sans_donnees"] == \
        [f"{debut} au {(aujourd_hui() - timedelta(days=1)).isoformat()}"]
    # Sans detail, le jour par jour ne part pas.
    assert "jours" not in outils.lire_sante(u, {})


def test_le_score_de_forme_dit_ce_qui_lui_manque(u):
    assert sql("SELECT score, manquantes FROM v_score_forme WHERE id_utilisateur = %s",
               u)[0]["score"] is None

    sql("SELECT recevoir_sante_jour(%s, jour_de(now()), NULL, NULL, NULL, 360)", u)

    forme = sql("SELECT score, etat, manquantes FROM v_score_forme "
                "WHERE id_utilisateur = %s", u)[0]
    assert forme["score"] == 75 and forme["etat"] == "vert"
    assert set(forme["manquantes"]) == {"variabilite", "frequence_repos", "charge"}


ACTIVITE = ("SELECT recevoir_activite(%s, %s, 'HKWorkoutActivityTypeRunning', 'course', "
            "now() - INTERVAL '3 hours', now() - INTERVAL '2 hours 20 minutes', %s)")


def test_une_seance_de_la_montre_se_rattache_a_la_seance_prevue(u, plan):
    prevue = proposer(u, dans=3, discipline="course", duree=40,
                      exercices=[{"code": "course_endurance", "duree_secondes": 2400}])
    reculer(prevue, 3)
    donnees = json.dumps({"distance_m": 7000, "fc_moyenne": 150,
                          "details": {"temps_par_km": [310, 305]}})

    premier = un(ACTIVITE, u, "ABC", donnees)
    second = un(ACTIVITE, u, "ABC", donnees)

    assert premier["id_occurrence"] == prevue and premier["creee"] and not second["creee"]
    assert un("SELECT count(*) FROM activite_sante") == 1
    assert un("SELECT details -> 'temps_par_km' FROM activite_sante") == [310, 305]
    # Elle fait compter la séance comme faite à 23 h (PLN-9).
    assert un("SELECT clore_seances_du_jour(%s)", u)["faites"] == [prevue]


def test_sans_seance_prevue_la_montre_cree_une_seance_libre(u):
    rendu = un(ACTIVITE, u, "XYZ", json.dumps({"fc_moyenne": 172, "fc_max": 190}))

    ligne = sql("SELECT libre, annoncee, discipline, intensite FROM seance "
                "WHERE id_occurrence = %s", rendu["id_occurrence"])[0]
    assert ligne == {"libre": True, "annoncee": False, "discipline": "course",
                     "intensite": "dure"}


def test_la_seance_libre_de_la_montre_porte_un_nom_francais(u):
    dehors = un(ACTIVITE, u, "DEHORS", "{}")["id_occurrence"]
    tapis = un("SELECT recevoir_activite(%s, 'TAPIS', 'running', 'course', "
               "now() - INTERVAL '6 hours', now() - INTERVAL '5 hours', %s)",
               u, json.dumps({"details": {"interieur": True}}))
    inconnue = un("SELECT recevoir_activite(%s, 'AUTRE', 'course matinale', 'course', "
                  "now() - INTERVAL '50 minutes', now() - INTERVAL '10 minutes')", u)

    def nom(occurrence):
        return un("SELECT type_seance FROM seance WHERE id_occurrence = %s", occurrence)

    assert nom(dehors) == "Course"
    assert nom(tapis["id_occurrence"]) == "Course sur tapis"
    # Un type que l'appli ne connaît pas : la séance s'appelle par sa discipline.
    assert nom(inconnue["id_occurrence"]) == "libre"


def test_une_seance_posee_apres_la_montre_la_retrouve_le_soir(u, plan):
    # SAN-9 : l'activité est arrivée quand le coach était coupé, la séance après.
    sql("UPDATE utilisateur SET coach_actif = FALSE WHERE id_utilisateur = %s", u)
    assert un(ACTIVITE, u, "TARD", "{}")["id_occurrence"] is None
    sql("UPDATE utilisateur SET coach_actif = TRUE WHERE id_utilisateur = %s", u)
    prevue = proposer(u, dans=3, discipline="course", duree=40,
                      exercices=[{"code": "course_endurance", "duree_secondes": 2400}])
    reculer(prevue, 3)

    bilan = planifie.clore_le_jour(u)

    assert un("SELECT id_occurrence FROM activite_sante") == prevue
    assert bilan["faites"] == [prevue]


def test_une_seance_posee_a_la_main_recoit_la_montre(u):
    # SAN-4 : une séance sans ligne `seance` (SPT-17) n'a pas de discipline. Sans
    # lieu, elle convient à toute activité du jour, au lieu d'une séance libre.
    debut = datetime.now(PARIS) - timedelta(hours=3, minutes=30)
    a_la_main = un("""
        INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, creneau, statut,
                                origine, debut_seance)
        SELECT t.id_tache, %s, tstzrange(%s, %s + INTERVAL '1 hour'),
               tstzrange(%s, %s + INTERVAL '1 hour'), 'planifiee', 'manuelle', %s
          FROM tache t WHERE t.id_tache = essais.tache_de('SPORT')
        RETURNING id_occurrence""", u, debut, debut, debut, debut, debut)
    if jour_de_paris(debut) != aujourd_hui():
        pytest.skip("Trop tôt dans la journée pour ce scénario")

    rendu = un(ACTIVITE, u, "MAIN", "{}")

    assert rendu["id_occurrence"] == a_la_main
    assert un("SELECT count(*) FROM seance") == 0
    assert un("SELECT situation FROM v_seance_coach WHERE id_occurrence = %s",
              a_la_main) == "faite"


def test_la_fenetre_d_un_test_prend_le_jour_de_sa_seance(u, plan):
    """MES-6 : le test de vendredi ne s'annonce pas samedi."""
    ouvrir = "SELECT ouvrir_fenetre_mesure(%s, 'test_course', %s, %s, 'à fond')"
    # Sans séance de test, HAL doit d'abord la proposer.
    assert refus(ouvrir, u, jour(4), jour(5)) == "requete_invalide"

    seance = un("SELECT proposer_seance(%s, 'course', 'test 3 km', 'dure', 40, %s, "
                "'07:00'::TIME, '21:00'::TIME, NULL, FALSE, TRUE)", u, jour(3))
    fenetre = un(ouvrir, u, jour(4), jour(5))

    ligne = sql("SELECT id_occurrence, lower(periode) AS du FROM fenetre_mesure "
                "WHERE id_fenetre = %s", fenetre)[0]
    assert ligne["id_occurrence"] == seance
    assert ligne["du"] == jour(3)

    # Déplacée au lendemain de sa fenêtre, la séance la garde ouverte.
    sql("UPDATE fenetre_mesure SET periode = daterange(CURRENT_DATE - 3, CURRENT_DATE, '[)') "
        "WHERE id_fenetre = %s", fenetre)
    sql("SELECT expirer_fenetres()")
    assert un("SELECT statut FROM fenetre_mesure WHERE id_fenetre = %s", fenetre) == "ouverte"


def test_la_migration_rattache_les_fenetres_de_test(u, plan):
    from pathlib import Path

    seance = un("SELECT proposer_seance(%s, 'course', 'test 3 km', 'dure', 40, %s, "
                "'07:00'::TIME, '21:00'::TIME, NULL, FALSE, TRUE)", u, jour(3))
    # Ouvertes comme avant : sans séance, à leurs propres dates.
    rattachee = un("INSERT INTO fenetre_mesure (id_utilisateur, type_mesure, periode) "
                   "VALUES (%s, 'test_course', daterange(%s, %s, '[]')) "
                   "RETURNING id_fenetre", u, jour(4), jour(5))
    orpheline = un("INSERT INTO fenetre_mesure (id_utilisateur, type_mesure, periode) "
                   "VALUES (%s, 'test_force', daterange(%s, %s, '[]')) "
                   "RETURNING id_fenetre", u, jour(4), jour(5))

    sql((Path(__file__).parent.parent / "sql" / "066_fenetres_des_tests.sql").read_text())

    ligne = sql("SELECT id_occurrence, lower(periode) AS du, statut FROM fenetre_mesure "
                "WHERE id_fenetre = %s", rattachee)[0]
    assert (ligne["id_occurrence"], ligne["du"], ligne["statut"]) == (seance, jour(3), "ouverte")
    assert un("SELECT statut FROM fenetre_mesure WHERE id_fenetre = %s", orpheline) == "expiree"


def test_la_montre_d_un_compte_sans_coach_ne_cree_pas_de_seance(base):
    rendu = un(ACTIVITE, _id("lorette"), "L1", "{}")
    assert rendu["id_occurrence"] is None and un("SELECT count(*) FROM seance") == 0


def test_une_fenetre_de_mesure_s_ouvre_se_remplit_ou_expire(u):
    ouvrir = "SELECT ouvrir_fenetre_mesure(%s, %s, CURRENT_DATE, CURRENT_DATE + 2, 'matin')"
    bras = un(ouvrir, u, "tour_bras")
    poids = un(ouvrir, u, "poids")
    assert refus(ouvrir, u, "poids") == "requete_invalide"
    assert refus("SELECT ouvrir_fenetre_mesure(%s, 'tour_taille', CURRENT_DATE, "
                 "CURRENT_DATE + 9)", u) == "requete_invalide"

    sql("SELECT saisir_mesure(%s, 'poids', 74.5, 'kg')", u)
    # Une mesure par côté : la fenêtre attend les deux.
    sql("SELECT saisir_mesure(%s, 'tour_bras', 34, 'cm', 'gauche')", u)
    assert un("SELECT statut FROM fenetre_mesure WHERE id_fenetre = %s", bras) == "ouverte"
    sql("SELECT saisir_mesure(%s, 'tour_bras', 35.5, 'cm', 'droite')", u)

    assert un("SELECT statut FROM fenetre_mesure WHERE id_fenetre = %s", poids) == "faite"
    assert un("SELECT statut FROM fenetre_mesure WHERE id_fenetre = %s", bras) == "faite"

    taille = un(ouvrir, u, "tour_taille")
    sql("UPDATE fenetre_mesure SET periode = daterange(CURRENT_DATE - 5, CURRENT_DATE - 2) "
        "WHERE id_fenetre = %s", taille)
    sql("SELECT expirer_fenetres()")
    assert un("SELECT statut FROM fenetre_mesure WHERE id_fenetre = %s", taille) == "expiree"


# ---------------------------------------------------------------------------
# La pause                                                              (PAU)
# ---------------------------------------------------------------------------

def test_la_pause_retire_les_propositions_et_ferme_la_porte(u, plan):
    proposee = proposer(u, dans=3)
    validee = proposer(u, dans=5, discipline="course", duree=30,
                       exercices=[{"code": "course_endurance", "duree_secondes": 1800}])
    sql("SELECT valider_seance(%s, %s)", u, validee)

    sql("SELECT mettre_en_pause(%s, CURRENT_DATE + 10, 'examens')", u)

    assert un("SELECT count(*) FROM occurrence WHERE id_occurrence = %s", proposee) == 0
    # Une séance validée est signalée, pas retirée : c'est l'utilisateur qui décide.
    assert un("SELECT statut FROM occurrence WHERE id_occurrence = %s", validee) == "planifiee"
    assert un("SELECT count(*) FROM notification WHERE type = 'coach'") == 1
    with pytest.raises(psycopg.Error) as erreur:
        proposer(u, dans=4)
    assert erreur.value.diag.constraint_name == "coach_en_pause"
    assert refus("SELECT mettre_en_pause(%s)", u) == "coach_en_pause"


def test_lever_la_pause_ferme_sa_periode_sans_l_effacer(u):
    sql("INSERT INTO pause (id_utilisateur, periode, motif) "
        "VALUES (%s, daterange(CURRENT_DATE - 4, NULL), 'grippe')", u)

    assert un("SELECT lever_pause(%s)", u) is True

    assert un("SELECT upper(periode) FROM pause") == aujourd_hui()
    assert un("SELECT en_pause(%s)", u) is False


def test_en_pause_la_synthese_passe_un_soir_sur_trois():
    assert [planifie.synthese_due({"jours_de_pause": n}) for n in range(7)] == \
        [True, False, False, True, False, False, True]
    assert planifie.synthese_due({"jours_de_pause": None})


def test_une_absence_retire_les_seances_proposees_qu_elle_couvre(u, plan):
    proposee = proposer(u, dans=3)
    debut = datetime.combine(jour(2), datetime.min.time(), tzinfo=PARIS)

    sql("INSERT INTO absence (id_utilisateur, periode, lieu, origine) "
        "VALUES (%s, tstzrange(%s, %s, '[)'), 'Lusse', 'manuelle')",
        u, debut, debut + timedelta(days=3))

    assert un("SELECT count(*) FROM occurrence WHERE id_occurrence = %s", proposee) == 0


# ---------------------------------------------------------------------------
# Les outils par moment                                               (COA-5)
# ---------------------------------------------------------------------------

def noms(moment: str, en_pause: bool = False) -> set[str]:
    return {o.nom for o in outils.outils_du_moment(moment, en_pause)}


def test_chaque_moment_a_ses_outils():
    seances = {"proposer_seance", "modifier_seance_proposee", "retirer_seance_proposee",
               "proposer_ajustement"}
    assert not noms("chat") & seances
    assert "requalifier_en_signalement" in noms("chat")
    assert all("requalifier_en_signalement" not in noms(m)
               for m in outils.MOMENTS if m != "chat")
    assert seances <= noms("synthese") and seances <= noms("signalement")
    assert "rendre_avis" in noms("faisabilite") and not noms("faisabilite") & seances
    assert {"ecrire_trame", "ecrire_feuille_de_route"} <= noms("plan") & noms("revision")
    assert "ecrire_trame" not in noms("synthese")
    assert "ouvrir_fenetre_mesure" not in noms("bilan")
    # Lire, chercher dans les échanges et tenir la mémoire sont permis à tout moment.
    for moment in outils.MOMENTS:
        assert {"lire_chapitre", "lire_semaine", "lire_echanges", "ecrire_memoire",
                "marquer_important"} <= noms(moment)


def test_en_pause_les_outils_de_seance_sont_fermes_partout():
    for moment in outils.MOMENTS:
        permis = noms(moment, en_pause=True)
        assert "proposer_seance" not in permis and "ecrire_trame" not in permis


def test_toutes_les_declarations_d_outils_sont_bien_formees():
    assert len({o.nom for o in outils.OUTILS}) == len(outils.OUTILS) == 26
    for outil in outils.OUTILS:
        declaration = outil.declaration()
        assert declaration["input_schema"]["type"] == "object"
        assert set(declaration["input_schema"]["required"]) <= \
            set(declaration["input_schema"]["properties"])


def test_un_outil_non_permis_est_refuse_et_dit_au_modele(u, plan):
    contenu, erreur = outils.executer_outil(
        "proposer_seance", u, {"discipline": "course"}, noms("chat"))
    assert erreur and json.loads(contenu)["refus"] == "outil_non_permis"


def test_un_refus_de_la_base_est_un_resultat_que_le_modele_peut_lire(u, plan, limitation):
    contenu, erreur = outils.executer_outil("proposer_seance", u, {
        "discipline": "musculation", "type_seance": "bras", "intensite": "moderee",
        "duree_minutes": 45, "jour": jour(3).isoformat(), "heure_min": "09:00",
        "heure_max": "20:00", "exercices": [{"code": "curl_barre", "series": 3}]},
        noms("synthese"))

    assert erreur
    assert json.loads(contenu) == {
        "refus": "exercice_interdit",
        "motif": "Curl barre droite est interdit par une limitation : paume vers le haut"}
    # SEC-5 : le refus de sécurité est noté au journal, en technique.
    assert un("SELECT count(*) FROM evenement WHERE objet = 'coach' AND technique") == 1


def test_le_catalogue_rendu_au_coach_ecarte_les_exercices_interdits(u, limitation):
    texte = outils.lire_catalogue(u, {"groupe": "biceps"})
    codes = {ligne.split(" | ")[0] for ligne in texte.splitlines()[1:]}
    assert "curl_barre" not in codes and "curl_marteau" in codes


def test_les_heures_rendues_au_modele_sont_celles_de_paris(u, plan):
    seance = proposer(u, plage=("18:00", "19:00"))
    rendu = outils.lire_semaine(u, {"lundi": jour(3).isoformat()})
    assert next(s for s in rendu["seances"]
                if s["id_occurrence"] == seance)["debut"].endswith("18:00")


# ---------------------------------------------------------------------------
# Un appel au coach, avec un faux modèle                         (opération C1)
# ---------------------------------------------------------------------------

class FauxModele:
    """Joue un scénario écrit tour par tour, et retient ce qu'on lui a envoyé."""

    def __init__(self, *tours):
        self.tours = list(tours)
        self.appels: list[dict] = []

    def __call__(self, systeme, messages, declarations, delai, modele_nom=None):
        self.appels.append({"systeme": systeme, "messages": json.loads(json.dumps(messages)),
                            "outils": [d["name"] for d in declarations],
                            "modele": modele_nom})
        if not self.tours:
            raise AssertionError("Le modèle a été appelé une fois de trop")
        tour = self.tours.pop(0)
        if isinstance(tour, Exception):
            raise tour
        return tour

    def resultats(self, rang: int = -1) -> list[dict]:
        """Les résultats d'outils rendus au modèle avant son appel n° `rang`."""
        return [b for b in self.appels[rang]["messages"][-1]["content"]
                if b["type"] == "tool_result"]


def dit(texte: str) -> modele.Tour:
    return modele.Tour(texte=texte, brut=[{"type": "text", "text": texte}], arret="end_turn",
                       tokens_entree=1000, tokens_cache=800, tokens_sortie=50)


def demande(*outils_voulus: tuple[str, dict]) -> modele.Tour:
    tour = modele.Tour(arret="tool_use", tokens_entree=1000, tokens_cache=800,
                       tokens_sortie=30)
    for rang, (nom, arguments) in enumerate(outils_voulus):
        identifiant = f"outil_{uuid.uuid4().hex[:8]}_{rang}"
        tour.outils.append(modele.DemandeOutil(identifiant, nom, arguments))
        tour.brut.append({"type": "tool_use", "id": identifiant, "name": nom,
                          "input": arguments})
    return tour


CONTROLE_DU_PLAN = appel.controle_du_plan


@pytest.fixture
def faux(monkeypatch):
    # Le contrôle du plan (COA-30) a son propre test : ailleurs, il ne rajoute
    # pas de passage aux scénarios écrits tour par tour.
    monkeypatch.setattr(appel, "controle_du_plan", lambda u: [])

    def installer(*tours) -> FauxModele:
        modele_joue = FauxModele(*tours)
        monkeypatch.setattr(modele, "appeler", modele_joue)
        return modele_joue
    return installer


def test_une_journee_sans_seance_a_une_synthese_legere(u, faux, monkeypatch):
    # COA-31 : socle seul, sans outils de séance, et le modèle simple s'il est réglé.
    monkeypatch.setattr(configuration(), "coach_modele_simple", "petit-modele")
    joue = faux(dit("Rien aujourd'hui. Demain, repos."))

    planifie.synthese(u, cloture={})

    premier = joue.appels[0]
    assert premier["modele"] == "petit-modele"
    assert not {"proposer_seances", "ouvrir_fenetre_mesure"} & set(premier["outils"])
    assert "Seul le socle est joint" in premier["systeme"][1]["text"]
    assert un("SELECT modele FROM appel_coach") == "petit-modele"

    # Sans réglage, le modèle du coach.
    monkeypatch.setattr(configuration(), "coach_modele_simple", "")
    joue = faux(dit("Réponse."))
    question(u)
    assert joue.appels[0]["modele"] == configuration().coach_modele


def test_les_anciens_messages_du_coach_sont_raccourcis(u, faux):
    # MEM-10 : le dernier message du coach reste entier, les précédents non.
    long = "Plan détaillé. " * 60
    faux(dit("Ancien : " + long))
    question(u, "Première")
    faux(dit("Récent : " + long))
    question(u, "Deuxième")
    joue = faux(dit("Ok."))
    question(u, "Troisième")
    texte = joue.appels[0]["messages"][0]["content"][0]["text"]
    assert "Ancien : " in texte and texte.count("Plan détaillé.") < 60 + 40
    assert ("Récent : " + long).strip() in texte


def test_un_message_pendant_un_plan_recoit_un_mot_d_attente(u):
    assert coach_tg.message_d_attente(u, "Mon 5 km : 29:30") is None
    sql("INSERT INTO appel_coach (id_utilisateur, moment, declencheur, operation, essai, "
        "modele) VALUES (%s, 'plan', 'systeme', 'op-plan', 1, 'x')", u)
    assert "plan" in coach_tg.message_d_attente(u, "Mon 5 km : 29:30")


def test_un_plan_est_relu_contre_ce_qui_est_pose(u, plan, faux, monkeypatch):
    # COA-30 : le message est relu une fois contre la base, quand des séances ont
    # été posées. « OK » garde le premier message.
    monkeypatch.setattr(appel, "controle_du_plan", CONTROLE_DU_PLAN)
    joue = faux(demande(("proposer_seance", SEANCE_DU_COACH | {"jour": jour(3).isoformat()})),
                dit("Plan annoncé, avec une sortie longue de 7,5 km."), dit("OK"))

    rendu = appel.appeler_coach(appel.Demande(u, "plan"))

    assert rendu["message"] == "Plan annoncé, avec une sortie longue de 7,5 km."
    relecture = joue.appels[2]["messages"][-1]["content"][0]["text"]
    assert "Relecture avant envoi" in relecture and "haut du corps" in relecture

    # Sans séance posée dans l'appel, pas de relecture.
    faux(dit("Rien à changer."))
    assert appel.appeler_coach(appel.Demande(u, "plan"))["message"] == "Rien à changer."


def question(u: int, texte: str = "Combien de protéines par jour ?", **reste) -> dict:
    return appel.appeler_coach(appel.Demande(id_utilisateur=u, moment="chat", texte=texte,
                                             **reste))


SEANCE_DU_COACH = {"discipline": "musculation", "type_seance": "haut du corps",
                   "intensite": "moderee", "duree_minutes": 60, "heure_min": "09:00",
                   "heure_max": "21:00", "exercices": EXOS_HAUT}


def test_une_reponse_a_une_forme_fixe_et_laisse_sa_trace(u, faux):
    joue = faux(dit("Vise 1,6 g par kilo."))

    rendu = question(u)

    assert rendu["message"] == "Vise 1,6 g par kilo."
    assert (rendu["moment"], rendu["auteur"], rendu["elements"]) == ("chat", "coach", [])
    echanges = sql("SELECT auteur, moment, contenu, modele, version_dossier, id_appel "
                   "FROM echange ORDER BY id_echange")
    assert [e["auteur"] for e in echanges] == ["utilisateur", "coach"]
    assert echanges[1]["modele"] == configuration().coach_modele
    assert echanges[1]["version_dossier"] == dossier.version()
    appel_enregistre = sql("SELECT statut, moment, declencheur, tours, tokens_entree, "
                           "tokens_cache, tokens_sortie, fin IS NOT NULL AS clos "
                           "FROM appel_coach")[0]
    assert appel_enregistre == {"statut": "termine", "moment": "chat",
                                "declencheur": "utilisateur", "tours": 0,
                                "tokens_entree": 1000, "tokens_cache": 800,
                                "tokens_sortie": 50, "clos": True}
    # NOT-11 : la notification est écrite avec l'échange, et le bot la transmet.
    assert sql("SELECT type, statut, id_echange FROM notification") == \
        [{"type": "coach", "statut": "a_envoyer", "id_echange": rendu["id_echange"]}]
    assert joue.appels[0]["outils"] == sorted(noms("chat"), key=joue.appels[0]["outils"].index)


def test_le_modele_recoit_la_consigne_puis_les_echanges_puis_le_moment(u, faux):
    faux(dit("Première réponse."))
    question(u, "Première question")
    joue = faux(dit("Deuxième réponse."))

    question(u, "Deuxième question")

    systeme, premier = joue.appels[0]["systeme"], joue.appels[0]["messages"][0]
    assert [bloc.get("cache_control") for bloc in systeme] == [{"type": "ephemeral"}] * 3
    texte = premier["content"][0]["text"]
    assert texte.index("Première réponse.") < texte.index("# Moment : chat") < \
        texte.index("Deuxième question")
    # Le texte de la demande n'y figure qu'une fois, pas aussi dans les échanges.
    assert texte.count("Deuxième question") == 1


def test_les_elements_viennent_de_la_base_pas_du_modele(u, plan, faux):
    # Le modèle annonce une séance qu'il n'a pas proposée : aucun bouton.
    faux(dit("Je t'ai ajouté une séance jeudi, valide-la !"))
    assert appel.appeler_coach(appel.Demande(u, "synthese"))["elements"] == []

    # Il la propose vraiment : l'élément existe, avec ses actions.
    faux(demande(("proposer_seance", SEANCE_DU_COACH | {"jour": jour(3).isoformat()})),
         dit("Séance posée."))
    rendu = appel.appeler_coach(appel.Demande(u, "synthese"))

    types = [e["type"] for e in rendu["elements"]]
    assert types == ["seance_proposee", "semaine_a_valider"]
    seance = rendu["elements"][0]
    assert seance["esquisse"] is False and seance["discipline"] == "musculation"
    assert [a["libelle"] for a in seance["actions"]] == \
        ["Valider", "Voir", "Déplacer", "Changer de lieu", "Supprimer"]
    assert rendu["elements"][1]["actions"][0]["route"].startswith("/plan/semaine/valider")
    assert un("SELECT elements FROM echange WHERE id_echange = %s",
              rendu["id_echange"])[0]["type"] == "seance_proposee"


def test_tout_ce_que_le_coach_change_porte_son_operation(u, plan, faux):
    faux(demande(("proposer_seance", SEANCE_DU_COACH | {"jour": jour(3).isoformat()}),
                 ("ecrire_memoire", {"niveau": "semaine", "texte": "Reprise"})),
         dit("Voilà."))

    appel.appeler_coach(appel.Demande(u, "synthese"))

    operation_id = un("SELECT operation FROM appel_coach")
    evenements = sql("SELECT acteur, origine FROM evenement WHERE operation = %s "
                     "AND objet = 'occurrence'", operation_id)
    assert evenements and all(e["acteur"] == "coach" for e in evenements)
    assert evenements[0]["origine"] == "coach : synthese"
    assert un("SELECT operation FROM echange WHERE auteur = 'coach'") == operation_id


def test_ce_qu_un_outil_a_ecrit_reste_meme_si_l_appel_echoue_ensuite(u, plan, faux):
    faux(demande(("proposer_seance", SEANCE_DU_COACH | {"jour": jour(3).isoformat()})),
         modele.ModeleInjoignable("coupure"))

    rendu = appel.appeler_coach(appel.Demande(u, "signalement", texte="J'ai mal dormi"))

    # COA-12 : le message fixe, tout de suite. COA-23 : la séance est restée.
    assert (rendu["auteur"], rendu["message"]) == ("systeme", reponse.MESSAGE_INJOIGNABLE)
    assert un("SELECT count(*) FROM seance WHERE auteur = 'coach'") == 1
    assert sql("SELECT statut, motif_echec FROM appel_coach")[0]["statut"] == "echoue"
    # Le texte de l'utilisateur est gardé, pour l'appel suivant.
    assert un("SELECT contenu FROM echange WHERE auteur = 'utilisateur'") == "J'ai mal dormi"


def test_les_lectures_du_moment_sont_jointes_d_office(u, plan, faux):
    # COA-28 : la synthèse reçoit sa semaine, sa santé et sa forme sans les demander.
    joue = faux(dit("Rien à signaler."))
    appel.appeler_coach(appel.Demande(u, "synthese"))
    texte = joue.appels[0]["messages"][0]["content"][0]["text"]
    assert "# Données lues pour toi" in texte
    for titre in ("lire_semaine", "lire_seance", "lire_sante", "lire_forme", "lire_planning"):
        assert f"({titre})" in texte
    assert texte.index("# Données lues") < texte.index("# Moment : synthese")

    # Le plan reçoit aussi le catalogue ; le chat, rien.
    joue = faux(dit("Plan."))
    appel.appeler_coach(appel.Demande(u, "plan"))
    assert "(lire_catalogue)" in joue.appels[0]["messages"][0]["content"][0]["text"]
    joue = faux(dit("Réponse."))
    question(u)
    assert "# Données lues" not in joue.appels[0]["messages"][0]["content"][0]["text"]


def test_plusieurs_seances_en_un_appel_gardent_chacune_leur_resultat(u, plan, faux):
    # COA-29 : une séance refusée n'empêche pas les autres d'être posées.
    joue = faux(demande(("proposer_seances", {"seances": [
        SEANCE_DU_COACH | {"jour": jour(3).isoformat()},
        SEANCE_DU_COACH | {"jour": "demain"},
        SEANCE_DU_COACH | {"jour": jour(5).isoformat()}]})), dit("Semaine posée."))

    rendu = appel.appeler_coach(appel.Demande(u, "plan"))

    assert un("SELECT count(*) FROM seance WHERE auteur = 'coach'") == 2
    resultat = json.loads(joue.resultats()[0]["content"])
    assert [("refus" in r) for r in resultat["resultats"]] == [False, True, False]
    assert resultat["resultats"][1]["refus"] == "requete_invalide"
    assert [e["type"] for e in rendu["elements"]].count("seance_proposee") == 2


def test_la_fiche_complete_d_une_limitation_ne_part_que_si_elle_sert(u, limitation, faux):
    # EXO-10 : le résumé à chaque appel, le détail pour la musculation.
    sql("UPDATE limitation SET description = 'Même charge des deux côtés.\n"
        "<!-- complet -->\nTableau de compatibilité détaillé.' WHERE id_limitation = %s",
        limitation)
    contexte_texte = contexte.texte(u)
    assert "Même charge des deux côtés." in contexte_texte
    assert "Tableau de compatibilité" not in contexte_texte
    assert "`curl_barre`" in contexte_texte

    # L'objectif de u est la prise de muscle : la musculation est en jeu.
    joue = faux(dit("Bilan."))
    appel.appeler_coach(appel.Demande(u, "synthese"))
    assert "Tableau de compatibilité" in joue.appels[0]["messages"][0]["content"][0]["text"]
    joue = faux(dit("Réponse."))
    question(u)
    assert "Tableau de compatibilité" not in joue.appels[0]["messages"][0]["content"][0]["text"]


def test_un_appel_d_outil_coupe_par_la_limite_n_est_pas_execute(u, plan, faux):
    # COA-27 : la réponse a atteint sa limite au milieu de la deuxième séance.
    coupe = demande(("proposer_seance", SEANCE_DU_COACH | {"jour": jour(3).isoformat()}),
                    ("proposer_seance", {"discipline": "course"}))
    coupe.arret = "max_tokens"
    joue = faux(coupe, dit("Une séance posée."))

    appel.appeler_coach(appel.Demande(u, "synthese"))

    assert un("SELECT count(*) FROM seance WHERE auteur = 'coach'") == 1
    premier, second = joue.resultats()
    assert "is_error" not in premier
    assert second["is_error"] and "demande_coupee" in second["content"]


def test_sans_cle_d_api_le_coach_repond_par_son_message_fixe(u, monkeypatch):
    monkeypatch.setattr(configuration(), "anthropic_api_key", "")
    monkeypatch.setattr(modele, "_clients", {})

    rendu = question(u)

    assert rendu["auteur"] == "systeme"
    assert "ANTHROPIC_API_KEY" in un("SELECT motif_echec FROM appel_coach")


def test_un_appel_est_borne_en_tours_d_outils(u, faux, monkeypatch):
    monkeypatch.setattr(configuration(), "coach_tours", 3)
    faux(*[demande(("lire_forme", {})) for _ in range(4)])

    rendu = question(u)

    assert rendu["auteur"] == "systeme"
    ligne = sql("SELECT statut, tours, motif_echec FROM appel_coach")[0]
    assert ligne["statut"] == "echoue" and "Borne de 3 tours" in ligne["motif_echec"]


def test_le_plan_et_la_revision_ont_trente_tours(u, plan, faux):
    faux(*[demande(("lire_forme", {})) for _ in range(20)], dit("Révision faite."))
    assert appel.appeler_coach(appel.Demande(u, "revision", "ordonnanceur"))["auteur"] == "coach"
    assert un("SELECT tours FROM appel_coach") == 20


def test_un_outil_interdit_dans_le_chat_n_ecrit_rien(u, plan, faux):
    joue = faux(demande(("proposer_seance", SEANCE_DU_COACH | {"jour": jour(3).isoformat()})),
                dit("Je ne peux pas toucher au plan d'ici, on voit ça ce soir."))

    rendu = question(u, "Ajoute-moi une séance jeudi")

    assert rendu["auteur"] == "coach" and rendu["elements"] == []
    resultat = joue.resultats()[0]
    assert resultat["is_error"] and "outil_non_permis" in resultat["content"]
    assert un("SELECT count(*) FROM seance") == 0


def test_une_douleur_dite_dans_le_chat_est_requalifiee_en_signalement(u, validee, faux):
    # Scénario de sécurité du chapitre 10.5.
    joue = faux(
        demande(("requalifier_en_signalement", {"raison": "douleur au coude"})),
        demande(("proposer_ajustement", {
            "id_occurrence": validee, "nature": "alleger", "motif": "gêne au coude",
            "contenu": {"duree_minutes": 40}})),
        dit("On allège la séance de demain. Si la gêne dépasse 5, on arrête."))

    rendu = question(u, "j'ai une gêne au coude gauche depuis ce matin, 4 sur 10")

    # Une seule réponse, dans le moment signalement, avec son ajustement.
    assert rendu["moment"] == "signalement"
    assert [e["type"] for e in rendu["elements"]] == ["ajustement"]
    assert un("SELECT count(*) FROM echange WHERE auteur = 'coach'") == 1
    assert sql("SELECT moment, statut FROM appel_coach") == \
        [{"moment": "signalement", "statut": "termine"}]
    assert un("SELECT moment FROM echange WHERE auteur = 'utilisateur'") == "signalement"
    # Les outils ont changé en cours d'appel : ceux du chat, puis ceux du signalement.
    assert "proposer_ajustement" not in joue.appels[0]["outils"]
    assert "proposer_ajustement" in joue.appels[1]["outils"]
    assert "requalifier_en_signalement" not in joue.appels[1]["outils"]


def test_un_coach_en_pause_ne_peut_rien_proposer(u, plan, faux):
    # Scénario de sécurité du chapitre 10.5.
    sql("SELECT mettre_en_pause(%s, NULL, 'vacances')", u)
    joue = faux(demande(("proposer_seance", SEANCE_DU_COACH | {"jour": jour(3).isoformat()})),
                dit("Bonnes vacances."))

    rendu = appel.appeler_coach(appel.Demande(u, "synthese", "ordonnanceur"))

    assert "proposer_seance" not in joue.appels[0]["outils"]
    assert rendu["elements"] == [] and un("SELECT count(*) FROM seance") == 0
    assert "en pause" in joue.appels[0]["systeme"][2]["text"]


def test_la_meme_cle_ne_rappelle_pas_le_modele(u, faux):
    joue = faux(dit("Une seule fois."))
    cle = str(uuid.uuid4())

    premier = question(u, cle_client=cle)
    second = question(u, cle_client=cle)

    assert second["id_echange"] == premier["id_echange"]
    assert len(joue.appels) == 1
    assert un("SELECT count(*) FROM echange WHERE auteur = 'utilisateur'") == 1


def test_un_compte_n_a_qu_un_appel_en_cours(u, faux, monkeypatch):
    monkeypatch.setattr(configuration(), "coach_delai_secondes", 2)
    monkeypatch.setattr(configuration(), "coach_delai_planifie_secondes", 2)
    sql("INSERT INTO appel_coach (id_utilisateur, moment, declencheur, operation, modele) "
        "VALUES (%s, 'synthese', 'ordonnanceur', 'autre', 'x')", u)
    joue = faux(dit("Ne devrait pas être appelé."))

    rendu = question(u)

    assert rendu["auteur"] == "systeme" and joue.appels == []
    # Au démarrage de l'API, un appel resté en cours trop longtemps est libéré.
    sql("UPDATE appel_coach SET debut = now() - INTERVAL '1 hour'")
    assert appel.liberer_les_appels_bloques() == 1
    assert question(u, "Et maintenant ?")["auteur"] == "coach"


def test_un_compte_sans_coach_est_refuse(base, faux):
    faux(dit("Non."))
    with pytest.raises(appel.CoachInactif):
        question(_id("lorette"))


def test_un_nouvel_essai_reprend_la_ou_l_appel_s_est_arrete(u, plan, faux, monkeypatch):
    # Une synthèse complète : celle d'un jour sans séance n'a pas d'outils de séance.
    monkeypatch.setattr(planifie, "journee_sans_seance", lambda u, cloture: False)
    faux(demande(("proposer_seance", SEANCE_DU_COACH | {"jour": jour(3).isoformat()})),
         modele.ModeleInjoignable("coupure"))
    with pytest.raises(appel.EchecAppel) as echec:
        planifie.synthese(u)

    joue = faux(dit("Synthèse terminée, la séance de jeudi est posée."))
    rendu = planifie.synthese(u, "synthese", None, echec.value.operation_id, 2)

    # COA-24 : même opération, et le modèle sait ce qui est déjà écrit.
    moment = joue.appels[0]["messages"][0]["content"][0]["text"]
    assert "essai n° 2" in moment and "seance_proposee" in moment
    assert [e["type"] for e in rendu["elements"]] == ["seance_proposee", "semaine_a_valider"]
    assert sql("SELECT essai, statut, operation FROM appel_coach ORDER BY id_appel") == [
        {"essai": 1, "statut": "echoue", "operation": echec.value.operation_id},
        {"essai": 2, "statut": "termine", "operation": echec.value.operation_id}]
    assert un("SELECT count(*) FROM seance") == 1


def test_le_soir_clot_le_jour_appelle_le_coach_et_fige_les_series(u, plan, faux):
    seance = proposer(u)
    reculer(seance, 4)
    sql("SELECT enregistrer_serie(%s, %s, %s, %s, 1, 40, 10)",
        u, seance, exo("presse_pectoraux"), uuid.uuid4())
    joue = faux(dit("Belle séance. Demain, repos."))

    bilan = planifie.soir()

    assert bilan == {"thomas": "revision" if aujourd_hui().weekday() == 6 else "synthese"}
    assert un("SELECT statut FROM occurrence WHERE id_occurrence = %s", seance) == "faite"
    assert un("SELECT figee FROM serie_saisie") is True
    assert f"[{seance}]" in joue.appels[0]["messages"][0]["content"][0]["text"]


def test_un_echec_du_soir_programme_un_nouvel_essai(u, plan, faux):
    faux(modele.ModeleInjoignable("coupure"))
    programmes = []

    planifie.soir(lambda *a: programmes.append(a))

    assert len(programmes) == 1
    minutes, compte, _, _, essai = programmes[0]
    assert (minutes, compte, essai) == (5, u, 2)


def test_apres_le_dernier_essai_un_message_le_dit(u, plan, faux):
    faux(modele.ModeleInjoignable("coupure"))

    assert planifie.nouvel_essai(u, "synthese", "op", 4, lambda *a: None) is False

    assert "n'a pas pu se faire" in un("SELECT contenu FROM notification WHERE type = 'coach'")
    # ADM-2 : l'administrateur du serveur en est prévenu par le bot.
    assert "injoignable" in un("SELECT contenu FROM notification WHERE type = 'administration'")


def test_le_journal_ne_garde_pas_le_texte_du_coach(u, faux):
    # CAR-8 : le journal se lit à deux, pas ce que le coach écrit à l'un.
    faux(dit("Ta gêne au coude m'inquiète un peu."))
    question(u)

    libelles = [e["libelle"] for e in sql("SELECT libelle FROM evenement "
                                          "WHERE objet = 'notification'")]
    assert libelles == ["Message du coach"]


# ---------------------------------------------------------------------------
# L'API                                                          (section 9.1)
# ---------------------------------------------------------------------------

def test_un_compte_sans_coach_recoit_un_refus_a_code_stable(client, thomas, lorette):
    # HDF-1 : sans HAL sport, c'est le HAL du foyer qui répond. Arrêté, plus personne.
    client.patch("/foyer", headers=thomas, json={"hal_actif": False})
    reponse_http = client.post("/coach/question", headers=lorette,
                               json={"texte": "Bonjour", "cle_client": str(uuid.uuid4())})
    assert reponse_http.status_code == 403
    assert reponse_http.json()["code"] == "coach_inactif"


def test_le_demarrage_d_un_compte_par_l_api(client, thomas, faux):
    assert client.put("/profil", headers=thomas, json={
        "date_naissance": "2000-01-01", "sexe": "homme", "taille_cm": 180,
        "niveau_musculation": "intermediaire", "niveau_course": "debutant"}).status_code == 200
    assert client.get("/depistage", headers=thomas).status_code == 404
    assert client.put("/disciplines/musculation/lieux", headers=thomas,
                      json=[lieu("SALLE")]).status_code == 200
    assert client.post("/coach/activer", headers=thomas).json()["manque"] == \
        ["aucun objectif principal actif"]
    limitation = client.post("/limitations", headers=thomas, json={
        "libelle": "Rotation limitée", "zone": "avant-bras", "cote": "gauche",
        "description": "Fiche"}).json()["id_limitation"]
    assert client.put(f"/limitations/{limitation}/interdits", headers=thomas, json=[
        {"code": "curl_barre", "motif": "paume vers le haut"}]).json()["interdits"] == 1

    # Créer l'objectif demande l'avis du coach, puis lance le plan en tâche de fond.
    joue = faux(demande(("rendre_avis", {"id_objectif": 1, "avis": "realiste",
                                         "detail": "Tenable en douze semaines."})),
                dit("Objectif réaliste."),
                dit("Plan construit."))
    sql("ALTER SEQUENCE objectif_id_objectif_seq RESTART WITH 1")
    rendu = client.post("/objectifs", headers=thomas, json={
        "type": "pilier", "pilier": "physique", "libelle": "Prendre du muscle",
        "principal": True}).json()

    assert rendu["objectif"]["avis"] == "realiste"
    assert rendu["coach"]["elements"][0]["type"] == "avis_objectif"
    assert rendu["coach"]["plan_en_construction"] is True
    assert joue.appels[0]["outils"].count("rendre_avis") == 1

    # Le plan part en tâche de fond, et se construit pour de bon : le troisième
    # tour du faux modèle lui est destiné.
    from api.routeurs import coach
    assert coach.attendre_les_taches_de_fond() == []
    assert len(joue.appels) == 3


def test_la_saisie_groupee_dit_le_sort_de_chaque_cle(client, thomas, u, validee, limitation):
    cles = [str(uuid.uuid4()) for _ in range(3)]
    series = [
        {"code": "presse_pectoraux", "cle_client": cles[0], "charge_kg": 40, "repetitions": 10},
        {"code": "curl_barre", "cle_client": cles[1], "charge_kg": 20, "repetitions": 10},
        {"code": "presse_pectoraux", "cle_client": cles[2], "charge_kg": 40, "repetitions": 9},
    ]

    premier = client.post(f"/seances/{validee}/series", headers=thomas, json=series).json()
    second = client.post(f"/seances/{validee}/series", headers=thomas, json=series).json()

    # Un refus sur une ligne ne fait pas échouer les autres.
    assert [s["etat"] for s in premier["series"]] == ["creee", "refusee", "creee"]
    assert premier["series"][1]["code"] == "exercice_interdit"
    assert [s["etat"] for s in second["series"]] == ["existait", "refusee", "existait"]


def test_le_bilan_par_l_api_et_le_refus_a_forme_fixe(client, thomas, u, validee):
    reculer(validee)
    rendu = client.post(f"/seances/{validee}/bilan", headers=thomas,
                        json={"effort": 6, "commentaire": "Facile"}).json()
    assert rendu["etat"] == "cree" and rendu["seance"]["seance"]["situation"] == "faite"

    refus_http = client.post("/plan/semaine/valider?lundi=2020-01-06", headers=thomas)
    assert refus_http.status_code == 404
    assert set(refus_http.json()) >= {"code", "message", "motif"}
    assert refus_http.json()["code"] == "introuvable"


def test_une_seance_de_muscu_saisie_dans_l_appli(client, thomas, u):
    # SAI-14 : la boucle de l'appli. Lancer, choisir un exercice, série par série,
    # retrouver la dernière fois, clore.
    def seance():
        return client.post("/seances/libre", headers=thomas, json={
            "discipline": "musculation", "cle_client": str(uuid.uuid4())}).json()

    premiere = seance()["seance"]["id_occurrence"]
    for charge, reps in ((40, 10), (42.5, 8)):
        rendu = client.post(f"/seances/{premiere}/series", headers=thomas, json={
            "code": "presse_pectoraux", "cle_client": str(uuid.uuid4()),
            "charge_kg": charge, "repetitions": reps}).json()
        assert rendu["series"][0]["etat"] == "creee"
    bilan = client.post(f"/seances/{premiere}/bilan", headers=thomas,
                        json={"effort": 7, "duree_minutes": 50}).json()
    assert bilan["seance"]["seance"]["situation"] == "faite"

    seconde = seance()["seance"]["id_occurrence"]
    avant = client.get(f"/exercices/presse_pectoraux/derniere-fois?avant={seconde}",
                       headers=thomas).json()
    assert [(s["charge_kg"], s["repetitions"]) for s in avant["series"]] == [(40, 10), (42.5, 8)]
    # SAI-20 : le plus lourd, et le plus lourd tenu sur dix répétitions.
    records = client.get("/exercices/presse_pectoraux/records", headers=thomas).json()
    assert (records["max"]["charge_kg"], records["max"]["repetitions"]) == (42.5, 8)
    assert (records["max_10"]["charge_kg"], records["max_10"]["repetitions"]) == (40, 10)
    jamais = client.get("/exercices/curl_concentre/records", headers=thomas).json()
    assert jamais["max"] is None and jamais["max_10"] is None
    catalogue = client.get("/exercices?discipline=musculation", headers=thomas).json()
    recents = [e["code"] for e in catalogue if e["derniere_saisie"]]
    assert recents == ["presse_pectoraux"]


def test_les_donnees_de_sante_par_l_api(client, thomas, u):
    aujourd = aujourd_hui().isoformat()
    assert client.put(f"/donnees-sante/jours/{aujourd}", headers=thomas,
                      json={"pas": 8000, "sommeil_minutes": 450}).json()["creee"] is True
    fin = datetime.now(PARIS) - timedelta(hours=1)
    rendu = client.put("/donnees-sante/activites/HK-1", headers=thomas, json={
        "type": "HKWorkoutActivityTypeTraditionalStrengthTraining",
        "debut": (fin - timedelta(minutes=50)).isoformat(), "fin": fin.isoformat(),
        "fc_moyenne": 118, "details": {"zones": {"z2": 1200}}}).json()

    assert rendu["discipline"] == "musculation" and rendu["id_occurrence"]
    assert client.get("/donnees-sante/fraicheur", headers=thomas).json()["dernier_jour"] == \
        aujourd
    # SAN-7 : l'autre personne ne lit pas ces données.
    assert client.get("/donnees-sante/jours", headers={"X-Cle-Api": "L" * 48}).json()[
        "jours"] == []


def test_les_echanges_ne_se_lisent_que_par_leur_proprietaire(client, thomas, lorette, u, faux):
    faux(dit("Réponse privée."))
    question(u)

    assert len(client.get("/coach/echanges", headers=thomas).json()) == 2
    assert client.get("/coach/echanges", headers=lorette).json() == []
    assert client.get("/coach/appels", headers=lorette).status_code == 403


# ---------------------------------------------------------------------------
# Le bot
# ---------------------------------------------------------------------------

def test_le_bot_se_tait_devant_le_texte_d_un_compte_sans_coach(base):
    assert coach_tg.texte_libre(_id("lorette"), "bonjour") is None


def test_un_texte_sans_commande_est_une_question_pour_le_coach(u, faux):
    faux(dit("Réponse avec un <b> qui ne doit pas casser l'affichage."))

    ecran = coach_tg.texte_libre(u, "Une question")

    assert "&lt;b&gt;" in ecran.texte and ecran.boutons == []
    # La réponse est affichée par le bot lui-même : elle ne part pas une 2e fois.
    assert un("SELECT statut FROM notification WHERE type = 'coach'") == "envoyee"


def test_la_semaine_s_affiche_avec_son_bouton_de_validation(u, plan):
    a, _ = _meme_semaine(2)
    seance = proposer(u, dans=a)

    ecran = coach_tg.commande("semaine", u, [])

    assert "à valider" in ecran.texte
    assert ecran.boutons[0][0][1] == f"co:sem:{lundi_de(jour(a)):%Y%m%d}"
    assert all(len(rappel.encode()) <= 64 for rangee in ecran.boutons for _, rappel in rangee)

    valide = coach_tg.repondre(u, "sem", f"{lundi_de(jour(a)):%Y%m%d}")
    assert "1 séance(s) validée(s)" in valide.texte
    assert un("SELECT etat FROM seance WHERE id_occurrence = %s", seance) == "validee"


def test_le_bouton_faite_demande_la_note_d_effort(u, validee):
    reculer(validee)
    assert coach_tg.est_seance_du_coach(validee)
    assert len(coach_tg.ecran_effort(validee).boutons[0]) == 5

    coach_tg.repondre(u, "eff", f"{validee}_7")

    assert un("SELECT effort FROM bilan_seance WHERE id_occurrence = %s", validee) == 7


def test_une_serie_se_saisit_depuis_le_bot(u, plan):
    seance = proposer(u)
    reculer(seance, 0.2)
    if jour_de_paris(datetime.now(PARIS) - timedelta(hours=0.2)) != aujourd_hui():
        pytest.skip("Trop tôt dans la journée pour ce scénario")

    ecran = coach_tg.commande("serie", u, ["presse_pectoraux", "42,5", "10"])

    assert "enregistrée" in ecran.texte
    assert sql("SELECT charge_kg, repetitions FROM serie_saisie")[0]["repetitions"] == 10


def test_le_profil_se_remplit_depuis_le_bot_sans_depistage(base):
    lorette = _id("lorette")
    coach_tg.commande("profil", lorette, ["1999-03-02", "femme", "165", "debutant",
                                          "intermediaire", "matin"])
    ecran = coach_tg.commande("profil", lorette, [])

    assert "pistage" not in ecran.texte and "médical" not in ecran.texte
    assert un("SELECT moment_prefere FROM profil WHERE id_utilisateur = %s", lorette) == "matin"


def test_une_commande_du_coach_ne_reste_jamais_muette(u):
    # Un refus de la base s'affiche tel quel, avec son motif.
    assert "Aucune séance" in coach_tg.repondre(u, "sem", "20200106").texte
    assert "pas activé" in coach_tg.commande("semaine", _id("lorette"), []).texte


def test_le_bot_ne_porte_plus_les_commandes_du_coach():
    # ADM-3 : tout se fait dans l'appli ; seule /hal reste, à l'administrateur.
    from api import bot

    noms = {nom for _, nom, *_ in bot.catalogue()}
    assert "hal" in noms and not (noms & set(coach_tg.COMMANDES) - {"hal"})

