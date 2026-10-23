"""Ajouter une tâche depuis le bot                                        (TAC-20)

Un cycle long, ou une chose à faire une fois avant une date. Cinq questions, des
boutons pour tout sauf le nom.

Ces tests jouent la conversation sans Telegram : `api.ajout` reçoit l'état de la
saisie et ce que la personne vient de faire, et rend l'écran suivant.
"""

from datetime import timedelta

import psycopg
import pytest

from api import ajout
from api.ordonnanceur import placer, report_de_minuit
from tests.test_ensemble import OUVERTS, _id, minuit, sql, un


def derouler(etat: dict, qui: int, *gestes: tuple[str, str]):
    """Enchaîne des boutons « (action, arguments) », et rend le dernier écran."""
    ecran = None
    for action, arguments in gestes:
        ecran = ajout.repondre(etat, qui, action, arguments)
    return ecran


def rappels(ecran) -> list[str]:
    return [rappel for rangee in ecran.boutons for _, rappel in rangee]


def tache(libelle: str) -> dict:
    return sql("SELECT * FROM tache WHERE libelle = %s", libelle)[0]


# ---------------------------------------------------------------------------
# Une tâche régulière : le cycle long
# ---------------------------------------------------------------------------

def test_un_cycle_long_en_cinq_questions(base):
    moi, etat = _id("thomas"), {}

    premier = ajout.ouvrir(etat)
    assert "Comment s'appelle la tâche ?" in premier.texte

    genre = ajout.texte(etat, moi, "Nettoyer le four")
    assert "Une seule fois, ou régulièrement ?" in genre.texte

    confirmation = derouler(etat, moi, ("g", "reg"), ("j", "90"), ("p", "0"), ("d", "30"))
    assert "tous les 3 mois, à tour de rôle, 30 min" in confirmation.texte
    assert rappels(confirmation) == ["tch:ok:1", "tch:ok:0"]

    fin = ajout.repondre(etat, moi, "ok", "1")

    assert fin.texte.startswith("Ajoutée : <b>Nettoyer le four</b>")
    creee = tache("Nettoyer le four")
    assert creee["recurrente"] is True
    assert (creee["periodicite_min_jours"], creee["periodicite_max_jours"]) == (90, 102)
    # PLA-14 : un cycle long passe après le ménage courant.
    assert creee["priorite"] == 5
    assert creee["duree_minutes"] == 30
    assert creee["id_utilisateur_defaut"] is None
    assert creee["ajoutee_par"] == moi
    # La saisie est finie : un message libre ne veut plus rien dire.
    assert etat == {}


def test_elle_est_placee_dans_la_foulee(base):
    moi, etat = _id("thomas"), {}
    ajout.ouvrir(etat, "Nettoyer le four")

    fin = derouler(etat, moi, ("g", "reg"), ("j", "30"), ("p", "0"), ("d", "15"), ("ok", "1"))

    assert "Première fois : " in fin.texte
    assert un(f"""SELECT count(*) FROM occurrence o JOIN tache t USING (id_tache)
                   WHERE t.libelle = 'Nettoyer le four' AND o.statut IN {OUVERTS}
                     AND o.creneau IS NOT NULL AND o.id_utilisateur IS NOT NULL""") >= 1


def test_un_autre_rythme_s_ecrit(base):
    moi, etat = _id("thomas"), {}
    ajout.ouvrir(etat, "Dégivrer le congélateur")

    question = derouler(etat, moi, ("g", "reg"), ("j", "0"))
    assert "Écris un nombre" in question.texte

    # Une réponse qui n'en est pas une : la question reste posée.
    assert "entre 1 et 730" in ajout.texte(etat, moi, "souvent").texte
    suite = ajout.texte(etat, moi, "45")

    assert "C'est pour qui ?" in suite.texte
    assert etat["jours"] == 45


def test_une_tache_reservee_a_quelqu_un(base):
    moi, elle, etat = _id("thomas"), _id("lorette"), {}
    ajout.ouvrir(etat, "Arroser les plantes")

    pour = derouler(etat, moi, ("g", "reg"), ("j", "7"))
    # « Moi », l'autre par son prénom, ou à tour de rôle.
    assert rappels(pour)[:3] == [f"tch:p:{moi}", f"tch:p:{elle}", "tch:p:0"]

    confirmation = derouler(etat, moi, ("p", str(elle)), ("d", "5"))
    assert "chaque semaine, pour Lorette, 5 min" in confirmation.texte
    ajout.repondre(etat, moi, "ok", "1")

    assert tache("Arroser les plantes")["id_utilisateur_defaut"] == elle
    # Hebdomadaire : priorité du ménage courant.
    assert tache("Arroser les plantes")["priorite"] == 4


# ---------------------------------------------------------------------------
# Une tâche ponctuelle : une fois, avant une date
# ---------------------------------------------------------------------------

def test_une_tache_a_faire_une_fois_avant_une_date(base):
    moi, etat = _id("thomas"), {}
    ajout.ouvrir(etat, "Rendre le colis")

    confirmation = derouler(etat, moi, ("g", "fois"), ("e", "3"), ("p", str(moi)), ("d", "15"))
    assert f"une fois, avant le {minuit(3):%d/%m}, pour toi, 15 min" in confirmation.texte
    ajout.repondre(etat, moi, "ok", "1")

    creee = tache("Rendre le colis")
    assert creee["recurrente"] is False
    # PLA-14 : une échéance passe avant le ménage courant.
    assert creee["priorite"] == 2
    (occurrence,) = sql(f"SELECT * FROM occurrence WHERE id_tache = %s AND statut IN {OUVERTS}",
                        creee["id_tache"])
    assert occurrence["id_utilisateur"] == moi
    assert occurrence["origine"] == "manuelle"
    # La fenêtre va d'aujourd'hui à la fin du jour de l'échéance, et le
    # placement a choisi un jour dedans.
    assert occurrence["fenetre"].upper == minuit(4)
    assert occurrence["creneau"] is not None
    assert occurrence["creneau"].lower < minuit(4)


def test_une_autre_date_s_ecrit(base):
    moi, etat = _id("thomas"), {}
    ajout.ouvrir(etat, "Renouveler la carte")
    derouler(etat, moi, ("g", "fois"), ("e", "x"))

    assert "pas compris" in ajout.texte(etat, moi, "bientôt").texte
    dans_dix_jours = minuit(10)
    suite = ajout.texte(etat, moi, f"{dans_dix_jours:%d/%m}")

    assert "C'est pour qui ?" in suite.texte
    assert etat["echeance"] == dans_dix_jours.date().isoformat()


def test_une_date_passee_est_refusee(base):
    moi, etat = _id("thomas"), {}
    ajout.ouvrir(etat, "Renouveler la carte")
    derouler(etat, moi, ("g", "fois"), ("e", "x"))
    hier = minuit(-1)

    reponse = ajout.texte(etat, moi, f"{hier:%d/%m/%Y}")

    assert "déjà passée" in reponse.texte
    assert etat["attend"] == "date"


def test_une_date_sans_annee_deja_passee_veut_dire_l_an_prochain(base):
    il_y_a_un_mois = minuit(-30).date()

    lue = ajout._lire_date(f"{il_y_a_un_mois:%d/%m}")

    assert lue == il_y_a_un_mois.replace(year=il_y_a_un_mois.year + 1)


@pytest.mark.parametrize("texte", ["31/02", "abc", "", "12/13", "0/5"])
def test_une_date_impossible_n_est_pas_lue(base, texte):
    assert ajout._lire_date(texte) is None


def test_une_tache_ponctuelle_ne_s_abandonne_pas_toute_seule(base):
    """Le ménage revient de lui-même, on peut en laisser passer un. Un colis non."""
    numero = un("SELECT ajouter_tache('Rendre le colis', %s, NULL, %s, %s, 15)",
                _id("thomas"), minuit(0).date(), _id("thomas"))
    # Six jours de retard : au-delà du délai d'abandon des tâches ordinaires.
    sql("""UPDATE occurrence SET fenetre = tstzrange(%s, %s, '[)'), statut = 'planifiee',
                                 creneau = tstzrange(%s, %s, '[)')
            WHERE id_tache = %s""",
        minuit(-7), minuit(-6), minuit(-7), minuit(-6), numero)

    report_de_minuit()

    statuts = {x["statut"] for x in sql("SELECT statut FROM occurrence WHERE id_tache = %s",
                                        numero)}
    assert "abandonnee" not in statuts
    assert statuts & {"a_placer", "planifiee", "notifiee"}, "elle est toujours à faire"


# ---------------------------------------------------------------------------
# Les sorties de route
# ---------------------------------------------------------------------------

def test_annuler_n_ajoute_rien(base):
    moi, etat = _id("thomas"), {}
    ajout.ouvrir(etat, "Nettoyer le four")
    avant = un("SELECT count(*) FROM tache")

    fin = derouler(etat, moi, ("g", "reg"), ("j", "90"), ("ok", "0"))

    assert "rien n'a été ajouté" in fin.texte
    assert un("SELECT count(*) FROM tache") == avant
    assert etat == {}


def test_un_bouton_reste_de_la_veille_le_dit(base):
    # Le bot a redémarré, ou le message traînait dans la conversation : l'état
    # de la saisie n'existe plus.
    reponse = ajout.repondre({}, _id("thomas"), "j", "90")

    assert "Refais /tache" in reponse.texte


def test_un_nom_trop_court_est_redemande(base):
    etat: dict = {}
    ajout.ouvrir(etat)

    reponse = ajout.texte(etat, _id("thomas"), "x")

    assert "2 à 100 caractères" in reponse.texte
    assert etat["attend"] == "nom"


def test_un_message_sans_question_en_cours_ne_veut_rien(base):
    assert ajout.texte({}, _id("thomas"), "bonjour") is None


def test_le_nom_est_echappe_a_l_ecran(base):
    etat: dict = {}

    ecran = ajout.ouvrir(etat, "Ranger <le> placard")

    # Les écrans partent en HTML : un chevron dans un nom casserait l'envoi.
    assert "Ranger &lt;le&gt; placard" in ecran.texte


def test_le_nom_donne_avec_la_commande_saute_la_premiere_question(base):
    etat: dict = {}

    ecran = ajout.ouvrir(etat, "Nettoyer   le four ")

    assert "Une seule fois, ou régulièrement ?" in ecran.texte
    assert etat["nom"] == "Nettoyer le four"


@pytest.mark.parametrize("jours, echeance", [(None, None), (7, "2099-01-01")])
def test_reguliere_ou_ponctuelle_pas_les_deux(base, jours, echeance):
    with pytest.raises(psycopg.errors.CheckViolation):
        sql("SELECT ajouter_tache('Essai', %s, %s, %s, NULL, 15)",
            _id("thomas"), jours, echeance)


# ---------------------------------------------------------------------------
# Celles qu'on a ajoutées
# ---------------------------------------------------------------------------

def test_la_liste_montre_les_taches_ajoutees(base):
    sql("SELECT ajouter_tache('Nettoyer le four', %s, 90, NULL, NULL, 30)", _id("thomas"))
    sql("SELECT ajouter_tache('Rendre le colis', %s, NULL, %s, NULL, 15)",
        _id("lorette"), minuit(3).date())

    ecran = ajout.ecran_liste()

    assert "• Nettoyer le four : tous les 90 jours" in ecran.texte
    assert f"• Rendre le colis : une fois, avant le {minuit(3):%d/%m}" in ecran.texte
    # Les tâches de référence n'y sont pas : on ne les arrête pas d'un bouton.
    assert "aspirateur" not in ecran.texte.lower()


def test_arreter_une_tache_ajoutee(base):
    numero = un("SELECT ajouter_tache('Nettoyer le four', %s, 30, NULL, NULL, 30)",
                _id("thomas"))
    placer()
    assert un(f"SELECT count(*) FROM occurrence WHERE id_tache = %s AND statut IN {OUVERTS}",
              numero) > 0

    ecran = ajout.repondre({}, _id("lorette"), "stop", str(numero))

    assert ecran.texte.startswith("Arrêtée : Nettoyer le four.")
    assert tache("Nettoyer le four")["active"] is False
    assert un(f"SELECT count(*) FROM occurrence WHERE id_tache = %s AND statut IN {OUVERTS}",
              numero) == 0
    assert "Nettoyer le four : tous les" not in ajout.ecran_liste().texte


def test_une_tache_de_reference_ne_s_arrete_pas_ainsi(base):
    aspirateur = un("SELECT id_tache FROM tache WHERE code = 'ASPIRATEUR'")

    assert un("SELECT arreter_tache(%s)", aspirateur) is False
    assert un("SELECT active FROM tache WHERE id_tache = %s", aspirateur) is True


def test_une_tache_ponctuelle_faite_quitte_la_liste(base):
    numero = un("SELECT ajouter_tache('Rendre le colis', %s, NULL, %s, %s, 15)",
                _id("thomas"), minuit(2).date(), _id("thomas"))
    placer()
    occurrence = un("SELECT id_occurrence FROM occurrence WHERE id_tache = %s", numero)

    sql("SELECT valider_occurrence(%s, %s, NULL)", occurrence, _id("thomas"))

    assert "Rendre le colis" not in ajout.ecran_liste().texte
    # Faite une fois, elle ne revient pas.
    assert un(f"SELECT count(*) FROM occurrence WHERE id_tache = %s AND statut IN {OUVERTS}",
              numero) == 0


def test_la_tache_ajoutee_entre_au_planning_comme_les_autres(base):
    sql("SELECT ajouter_tache('Nettoyer le four', %s, 30, NULL, NULL, 30)", _id("thomas"))

    placer()

    prevue = sql(f"""SELECT o.creneau, o.id_utilisateur FROM occurrence o
                      JOIN tache t USING (id_tache)
                     WHERE t.libelle = 'Nettoyer le four' AND o.statut IN {OUVERTS}
                     ORDER BY lower(o.fenetre) LIMIT 1""")[0]
    assert prevue["creneau"] is not None
    # Jamais faite : due dans le mois qui vient, pas dans trois mois.
    assert prevue["creneau"].lower < minuit(0) + timedelta(days=35)
