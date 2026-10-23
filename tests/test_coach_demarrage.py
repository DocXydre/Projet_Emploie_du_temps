"""Le démarrage du coach dans le bot, question par question.      (DEM-1 à DEM-4)"""

# ruff: noqa: F811 (les fixtures de test_coach sont importées puis demandées)

import pytest

from api.coach import demarrage
from api.coach import telegram as coach_tg
from tests.test_coach import dit, faux, u  # noqa: F401
from tests.test_ensemble import _id, sql, un


@pytest.fixture
def nu(base) -> int:
    """Thomas, coach activé, et rien d'autre. activer_coach() demande un profil :
    c'est le cas d'un compte activé puis vidé, ou activé à la main."""
    u = _id("thomas")
    sql("UPDATE utilisateur SET coach_actif = TRUE WHERE id_utilisateur = %s", u)
    return u


def bouton(u: int, rappel: str):
    assert rappel.startswith("co:dm:"), rappel
    return coach_tg.repondre(u, "dm", rappel[len("co:dm:"):])


def rappels(ecran) -> list[str]:
    return [r for rangee in ecran.boutons for _, r in rangee]


def test_tant_que_rien_n_est_rempli_le_coach_renvoie_au_demarrage(nu):
    assert demarrage.bloc_manquant(nu) == "profil"
    # Un message libre ne part pas au modèle : c'est la réponse à la question.
    ecran = coach_tg.texte_libre(nu, "Combien de séries pour progresser ?")
    assert "étape 1 sur 4" in ecran.texte and "Je n'ai pas compris la date" in ecran.texte
    # Une commande du coach est refusée, avec la question en cours.
    ecran = coach_tg.commande("semaine", nu, [])
    assert "finir ton démarrage" in ecran.texte and "date de naissance" in ecran.texte
    # Les commandes de démarrage, elles, restent ouvertes.
    assert "démarrage" not in coach_tg.commande("lieux", nu, []).texte.lower()
    # Un autre bouton du coach aussi renvoie au démarrage.
    assert "Finissons d'abord" in coach_tg.repondre(nu, "plan", "0").texte


def test_le_demarrage_complet_au_bout_des_boutons(nu, faux):
    faux(dit("Objectif réaliste. Je construis ton plan quand tu veux."))
    ecran = coach_tg.commande("initialiser", nu, [])
    assert "Question 1 sur 9" in ecran.texte

    # Le profil.
    ecran = coach_tg.texte_libre(nu, "14/03/2002")
    ecran = bouton(nu, "co:dm:sexe=homme")
    ecran = coach_tg.texte_libre(nu, "180 cm")
    ecran = bouton(nu, "co:dm:niveau_musculation=intermediaire")
    ecran = bouton(nu, "co:dm:niveau_course=debutant")
    ecran = bouton(nu, "co:dm:moment_prefere=soir")
    assert "co:dm:j=7" in rappels(ecran)
    ecran = bouton(nu, "co:dm:j=7")
    assert "✅ Dim" in str(ecran.boutons)
    ecran = bouton(nu, "co:dm:j=3")
    ecran = bouton(nu, "co:dm:j=3")              # retouché : retiré
    ecran = bouton(nu, "co:dm:jok=1")
    ecran = bouton(nu, "co:dm:accord_complements=0")
    ecran = bouton(nu, "co:dm:regime=-")
    assert "Profil enregistré" in ecran.texte and "étape 2 sur 4" in ecran.texte
    profil = sql("SELECT sexe, taille_cm, jours_sans_sport, regime, moment_prefere "
                 "FROM profil WHERE id_utilisateur = %s", nu)[0]
    assert profil == {"sexe": "homme", "taille_cm": 180, "jours_sans_sport": [7],
                      "regime": None, "moment_prefere": "soir"}

    # Pas de questionnaire de santé : la question des limitations, une au bras.
    assert "douleur ou une limitation" in ecran.texte
    ecran = bouton(nu, "co:dm:lim_question=1")
    ecran = bouton(nu, "co:dm:lim_zone=avant-bras")
    ecran = bouton(nu, "co:dm:lim_cote=gauche")
    ecran = coach_tg.texte_libre(nu, "Je ne peux pas tourner l'avant-bras paume vers le haut")
    assert "Limitation notée" in ecran.texte and "Une autre" in ecran.texte
    ecran = bouton(nu, "co:dm:lim_autre=0")
    assert "étape 3 sur 4" in ecran.texte
    assert sql("SELECT libelle, zone, cote FROM limitation WHERE id_utilisateur = %s", nu) \
        == [{"libelle": "Avant-bras (gauche)", "zone": "avant-bras", "cote": "gauche"}]
    assert un("SELECT count(*) FROM depistage") == 0

    # Les lieux : un pour la musculation, aucun pour la course, un pour le cardio.
    lieu = next(r for r in rappels(ecran) if r.startswith("co:dm:l="))
    ecran = bouton(nu, lieu)
    ecran = bouton(nu, "co:dm:lok=1")
    assert "Lieux de musculation enregistrés" in ecran.texte and "course" in ecran.texte
    ecran = bouton(nu, "co:dm:lok=1")
    assert "cardio" in ecran.texte
    ecran = bouton(nu, lieu)
    ecran = bouton(nu, "co:dm:lok=1")
    assert "étape 4 sur 4" in ecran.texte
    assert {r["discipline"] for r in sql(
        "SELECT discipline FROM discipline_lieu WHERE id_utilisateur = %s", nu)} == \
        {"musculation", "cardio"}

    # L'objectif : une course, sa distance, le temps visé, sa date.
    ecran = bouton(nu, "co:dm:objectif=course")
    ecran = coach_tg.texte_libre(nu, "15 km")
    assert "En combien de temps" in ecran.texte
    ecran = coach_tg.texte_libre(nu, "1h05")
    ecran = coach_tg.texte_libre(nu, "12/04/2027")
    assert "Le démarrage est fini" in ecran.texte
    # L'avis du coach arrive par son message, pas recopié ici (sinon deux fois).
    assert "Objectif réaliste" not in ecran.texte and "arrive juste après" in ecran.texte
    assert "co:dm:plan=1" in rappels(ecran)
    objectif = sql("SELECT type, libelle, distance_m, cible_valeur, cible_unite, principal "
                   "FROM objectif WHERE id_utilisateur = %s", nu)[0]
    assert objectif == {"type": "course", "libelle": "15 km en 1h05", "distance_m": 15000,
                        "cible_valeur": 65, "cible_unite": "min", "principal": True}
    assert not demarrage.requis(nu)
    assert un("SELECT etape FROM demarrage_coach") == "fini"


def test_un_refus_repose_la_question(nu):
    coach_tg.commande("initialiser", nu, [])
    # PRO-7 : moins de 18 ans, la base refuse le profil à la fin du bloc.
    coach_tg.texte_libre(nu, "01/01/2015")
    for rappel in ("co:dm:sexe=homme",):
        bouton(nu, rappel)
    coach_tg.texte_libre(nu, "170")
    for rappel in ("co:dm:niveau_musculation=debutant", "co:dm:niveau_course=debutant",
                   "co:dm:moment_prefere=matin", "co:dm:jok=1",
                   "co:dm:accord_complements=0"):
        bouton(nu, rappel)
    ecran = bouton(nu, "co:dm:regime=-")
    assert "❌" in ecran.texte and "date de naissance" in ecran.texte
    assert un("SELECT count(*) FROM profil") == 0


def test_un_vieux_bouton_ne_casse_rien(nu):
    coach_tg.commande("initialiser", nu, [])
    ecran = bouton(nu, "co:dm:niveau_course=avance")   # pas encore la bonne question
    assert "date de naissance" in ecran.texte


def test_un_compte_deja_pret_n_est_pas_force(nu):
    from tests.test_coach import lieu
    sql("INSERT INTO profil (id_utilisateur, date_naissance, sexe, taille_cm, "
        "niveau_musculation, niveau_course) VALUES (%s, '2000-01-01', 'homme', 180, "
        "'debutant', 'debutant')", nu)
    sql("INSERT INTO discipline_lieu VALUES (%s, 'course', %s, 1)", nu, lieu("COURSE"))
    sql("INSERT INTO objectif (id_utilisateur, type, libelle, pilier, principal) "
        "VALUES (%s, 'pilier', 'Force', 'force', true)", nu)
    # Profil, lieux et objectif sont là : il ne reste que la question des
    # limitations, posée une fois. Un « non » la clôt pour de bon.
    assert demarrage.bloc_manquant(nu) == "limitations"
    ecran = coach_tg.texte_libre(nu, "Combien de séries ?")
    assert "douleur ou une limitation" in ecran.texte
    ecran = bouton(nu, "co:dm:lim_question=0")
    assert "Le démarrage est fini" in ecran.texte
    assert not demarrage.requis(nu)


def test_un_temps_vise_se_lit_comme_on_l_ecrit():
    assert demarrage.lire_duree("50 min") == 50
    assert demarrage.lire_duree("1h45") == 105
    assert demarrage.lire_duree("1 h") == 60
    assert demarrage.lire_duree("52:30") == 52.5
    assert demarrage.lire_duree("1:05:00") == 65
    assert demarrage.lire_duree("vite") is None
    assert demarrage.duree_en_clair(52.5) == "52 min 30"


# ---------------------------------------------------------------------------
# Repartir de zéro                                                       (DEM-5)
# ---------------------------------------------------------------------------

def _rempli(u: int) -> None:
    from tests.test_coach import proposer
    sql("SELECT construire_plan(%s, lundi_de(jour_de(now())), 'Trame', "
        "ARRAY['charge', 'charge', 'charge', 'allegee'])", u)
    proposer(u, dans=2)
    sql("INSERT INTO limitation (id_utilisateur, libelle, zone, cote, description) "
        "VALUES (%s, 'Coude', 'coude', 'gauche', 'gêne')", u)
    sql("SELECT ecrire_memoire(%s, 'globale', 'Préfère le soir', 'utilisateur')", u)
    sql("INSERT INTO echange (id_utilisateur, auteur, moment, contenu) "
        "VALUES (%s, 'utilisateur', 'chat', 'Bonjour')", u)
    sql("INSERT INTO sante_jour (id_utilisateur, jour, pas) VALUES (%s, CURRENT_DATE - 1, 9000)",
        u)
    # Le ménage de la maison : des occurrences qui ne sont pas au coach.
    from api.ordonnanceur import placer
    placer()


COACH = ("profil", "limitation", "objectif", "plan", "seance", "discipline_lieu",
         "memoire_coach", "echange")


def _compte(table: str, u: int) -> int:
    colonne = "o.id_utilisateur" if table == "seance" else "x.id_utilisateur"
    jointure = "JOIN occurrence o USING (id_occurrence)" if table == "seance" else ""
    return un(f"SELECT count(*) FROM {table} x {jointure} WHERE {colonne} = %s", u)


def test_reinitialiser_efface_le_coach_et_garde_le_reste(u):
    _rempli(u)
    autres = un("SELECT count(*) FROM occurrence o WHERE o.id_utilisateur = %s AND NOT EXISTS "
                "(SELECT 1 FROM seance s WHERE s.id_occurrence = o.id_occurrence)", u)
    assert autres >= 1 and all(_compte(t, u) for t in COACH)

    ecran = coach_tg.commande("reinitialiser", u, [])
    assert "définitif" in ecran.texte and "co:rz:sante" in rappels(ecran)
    assert "Rien n'a été effacé" in coach_tg.repondre(u, "rz", "non").texte
    assert _compte("profil", u) == 1

    ecran = coach_tg.repondre(u, "rz", "sante")
    assert "C'est effacé" in ecran.texte and "étape 1 sur 4" in ecran.texte
    assert {t: _compte(t, u) for t in COACH} == dict.fromkeys(COACH, 0)
    # L'emploi du temps, la montre et l'activation restent.
    assert un("SELECT count(*) FROM occurrence WHERE id_utilisateur = %s", u) == autres
    assert un("SELECT count(*) FROM sante_jour WHERE id_utilisateur = %s", u) == 1
    assert un("SELECT coach_actif FROM utilisateur WHERE id_utilisateur = %s", u) is True
    assert demarrage.requis(u)


def test_reinitialiser_tout_efface_aussi_la_montre(u):
    _rempli(u)
    ecran = coach_tg.repondre(u, "rz", "tout")
    assert "Envoyer tout l'historique" in ecran.texte
    assert un("SELECT count(*) FROM sante_jour WHERE id_utilisateur = %s", u) == 0
    # Le compte de l'autre personne n'est pas touché.
    assert un("SELECT count(*) FROM utilisateur") == 2


def test_les_limitations_s_importent_seules_depuis_le_fichier(u, monkeypatch, capsys):
    import io
    import json
    import sys

    from outils import coach_demarrer
    fiche = {"pseudo": "thomas",
             "profil": {"date_naissance": "AAAA-MM-JJ"},       # ignoré avec --limitations
             "limitations": [{"libelle": "Rotation limitée de l'avant-bras gauche",
                              "zone": "avant-bras", "cote": "gauche",
                              "description": "Jamais paume vers le haut à gauche.",
                              "interdits": [{"code": "curl_barre", "motif": "supination"}]}]}
    sql("DELETE FROM demarrage_coach")
    monkeypatch.setattr(sys, "stdin", io.StringIO(json.dumps(fiche)))
    monkeypatch.setattr(sys, "argv", ["coach_demarrer", "--limitations"])
    assert coach_demarrer.main() == 0
    assert "1 exercice(s) interdit(s)" in capsys.readouterr().out
    assert un("SELECT count(*) FROM exercice_interdit ei JOIN limitation l "
              "USING (id_limitation) WHERE l.id_utilisateur = %s", u) == 1
    # Le démarrage ne reposera pas la question des limitations.
    assert demarrage.bloc_manquant(u) is None
