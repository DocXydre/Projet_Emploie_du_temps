"""Le mode allégé                                                        (PLA-16)

Une semaine d'examens, un coup de fatigue. Celui qui l'active fait un quart des
tâches partagées pendant la durée qu'il donne, l'autre trois quarts. Activé par
les deux en même temps, il s'annule : on ne vit pas dans la crasse.

Et comme pour une absence, ce qui a été réparti inégalement parce qu'on l'a
voulu ne se rattrape pas la semaine suivante.
"""


import psycopg
import pytest

from api import allegement, journal, operation
from api.ordonnanceur import placer
from tests.test_ensemble import OUVERTS, _id, minuit, sql, un


def minutes(du, au) -> dict[str, int]:
    """Les minutes de tâches partagées de chacun, sur une période."""
    lignes = sql(f"""
        SELECT u.pseudo, COALESCE(sum(t.duree_minutes), 0)::INTEGER AS minutes
          FROM occurrence o JOIN tache t USING (id_tache)
          JOIN utilisateur u USING (id_utilisateur)
         WHERE o.statut IN {OUVERTS}
           AND t.id_type_tache IS NOT NULL
           AND t.id_utilisateur_defaut IS NULL
           AND lower(COALESCE(o.creneau, o.fenetre)) >= %s
           AND lower(COALESCE(o.creneau, o.fenetre)) < %s
         GROUP BY u.pseudo""", du, au)
    return {"thomas": 0, "lorette": 0, **{x["pseudo"]: x["minutes"] for x in lignes}}


def charges() -> dict[str, int]:
    """La charge de chacun, celle que la répartition de tous les jours équilibre."""
    return {p: un("SELECT charge_domestique(%s)", _id(p)) for p in ("thomas", "lorette")}


def tolerance() -> int:
    """PLA-12 : moins d'une heure d'écart, à une tâche près."""
    return 60 + un("SELECT max(duree_minutes) FROM tache WHERE active "
                   "AND id_type_tache IS NOT NULL "
                   "AND id_utilisateur_defaut IS NULL")


def alertes(pseudo: str) -> list[str]:
    return [x["contenu"] for x in sql(
        "SELECT contenu FROM notification WHERE id_utilisateur = %s AND type = 'alerte' "
        " ORDER BY id_notification", _id(pseudo))]


@pytest.fixture
def place(base):
    placer()
    sql("DELETE FROM notification")
    sql("DELETE FROM evenement")


# ---------------------------------------------------------------------------
# Un quart, trois quarts
# ---------------------------------------------------------------------------

def test_celui_qui_s_allege_fait_un_quart(place):
    allegement.activer(_id("thomas"), 7)

    part = minutes(minuit(1), minuit(7))

    total = part["thomas"] + part["lorette"]
    assert total >= 40, "il faut assez de tâches sur la semaine pour juger"
    # Un quart, à une tâche près : les tâches ne se coupent pas en morceaux.
    assert part["thomas"] <= total / 4 + 15, part
    assert part["thomas"] > 0, "allégé ne veut pas dire dispensé"


def test_l_autre_est_prevenu(place):
    ecran = allegement.activer(_id("thomas"), 3)

    assert "mode allégé jusqu'à" in ecran.texte
    assert "Tu fais un quart des tâches partagées, Lorette le reste" in ecran.texte
    (message,) = alertes("lorette")
    assert message.startswith("Thomas passe en mode allégé jusqu'à ")
    assert "tu récupères une partie de ses tâches" in message
    assert alertes("thomas") == []


def test_ce_qui_est_reserve_reste_a_son_proprietaire(place):
    reservee = un("SELECT creer_tache('Arroser le ficus', %s, p_tous_les_jours => 2, p_pour => %s, "
                  "p_duree_minutes => 5)",
                  _id("thomas"), _id("thomas"))
    placer()

    allegement.activer(_id("thomas"), 7)

    a_qui = {x["id_utilisateur"] for x in sql(
        f"SELECT id_utilisateur FROM occurrence WHERE id_tache = %s "
        f"   AND statut IN {OUVERTS} AND creneau IS NOT NULL", reservee)}
    assert a_qui == {_id("thomas")}


def test_apres_la_periode_la_repartition_redevient_normale(place):
    allegement.activer(_id("thomas"), 4)

    apres = minutes(minuit(5), minuit(15))

    # Ni reste d'allègement, ni rattrapage : Lorette a pris le relais quatre
    # jours, Thomas ne lui doit pas le ménage de la semaine suivante.
    assert abs(apres["thomas"] - apres["lorette"]) <= 60, apres


def test_les_jours_alleges_ne_comptent_pas_dans_la_balance(place):
    allegement.activer(_id("thomas"), 4)

    hors_periode = un(f"""
        SELECT COALESCE(sum(t.duree_minutes), 0) FROM occurrence o JOIN tache t USING (id_tache)
         WHERE o.id_utilisateur = %s AND o.statut IN {OUVERTS}
           AND t.id_type_tache IS NOT NULL
           AND lower(COALESCE(o.creneau, o.fenetre)) >= %s""",
                      _id("lorette"), minuit(4))

    assert un("SELECT charge_domestique(%s)", _id("lorette")) == hors_periode


# ---------------------------------------------------------------------------
# À deux, il s'annule
# ---------------------------------------------------------------------------

def test_active_par_les_deux_il_s_annule(place):
    allegement.activer(_id("thomas"), 7)
    ecran = allegement.activer(_id("lorette"), 7)

    assert "Thomas l'est aussi" in ecran.texte
    assert "les deux s'annulent" in ecran.texte
    assert un("SELECT est_allege(%s, %s)", _id("thomas"), minuit(2).date()) is False
    assert un("SELECT est_allege(%s, %s)", _id("lorette"), minuit(2).date()) is False

    # La répartition est celle de tous les jours : la balance porte sur toute la
    # charge. Sur quelques jours, elle peut pencher d'un côté pour rattraper le
    # reste du planning, que la remise en répartition n'a pas touché.
    charge = charges()
    assert abs(charge["thomas"] - charge["lorette"]) <= tolerance(), charge


def test_il_ne_s_annule_que_les_jours_communs(place):
    allegement.activer(_id("thomas"), 7)
    allegement.activer(_id("lorette"), 2)

    # Demain : les deux. Dans quatre jours : Thomas seul.
    assert un("SELECT est_allege(%s, %s)", _id("thomas"), minuit(1).date()) is False
    assert un("SELECT est_allege(%s, %s)", _id("thomas"), minuit(4).date()) is True


# ---------------------------------------------------------------------------
# Une durée, donnée au lancement
# ---------------------------------------------------------------------------

def test_trois_jours_courent_jusqu_a_apres_demain_soir(place):
    allegement.activer(_id("thomas"), 3)

    fin = un("SELECT upper(periode) FROM allegement WHERE id_utilisateur = %s", _id("thomas"))

    assert fin == minuit(3)
    assert un("SELECT est_allege(%s, %s)", _id("thomas"), minuit(2).date()) is True
    assert un("SELECT est_allege(%s, %s)", _id("thomas"), minuit(3).date()) is False


def test_relancer_change_la_duree_sans_empiler(place):
    allegement.activer(_id("thomas"), 3)
    allegement.activer(_id("thomas"), 7)

    periodes = sql("SELECT upper(periode) AS fin FROM allegement WHERE id_utilisateur = %s",
                   _id("thomas"))
    assert [p["fin"] for p in periodes] == [minuit(7)]


@pytest.mark.parametrize("jours", [0, 15, -2])
def test_la_duree_va_de_un_a_quatorze_jours(base, jours):
    # Un mode qu'on oublie allumé finit par devenir la répartition normale.
    with pytest.raises(psycopg.errors.CheckViolation):
        sql("SELECT activer_allegement(%s, %s)", _id("thomas"), jours)


def test_la_commande_refuse_une_duree_farfelue(base):
    ecran = allegement.commande(_id("thomas"), ["trente"])

    assert "entre 1 et 14" in ecran.texte
    assert un("SELECT count(*) FROM allegement") == 0


# ---------------------------------------------------------------------------
# Arrêter avant la fin
# ---------------------------------------------------------------------------

def test_arreter_rend_la_repartition_normale(place):
    allegement.activer(_id("thomas"), 7)
    sql("DELETE FROM notification")

    ecran = allegement.commande(_id("thomas"), ["stop"])

    assert "arrêté" in ecran.texte
    assert allegement.en_cours(_id("thomas")) is None
    assert alertes("lorette") == [
        "Thomas a arrêté son mode allégé : la répartition redevient moitié-moitié."]
    charge = charges()
    assert abs(charge["thomas"] - charge["lorette"]) <= tolerance(), charge
    # Dès l'arrêt, même pour le reste de la journée : une tâche neuve va au
    # moins chargé, et non plus d'office à Lorette.
    neuve = un("SELECT creer_tache('Arroser le ficus', %s, p_tous_les_jours => 7)", _id("thomas"))
    choisi = un("SELECT choisir_assigne(%s, tstzrange(now(), now() + INTERVAL '2 days'))",
                neuve)
    assert choisi == _id(min(charge, key=charge.get)), charge


def test_arreter_sans_etre_allege_le_dit(base):
    assert "pas en mode allégé" in allegement.arreter(_id("thomas")).texte


# ---------------------------------------------------------------------------
# Ce qu'on lit
# ---------------------------------------------------------------------------

def test_l_ecran_propose_des_durees_puis_dit_ou_on_en_est(place):
    avant = allegement.ecran(_id("thomas"))
    assert "Pour combien de temps ?" in avant.texte
    assert [rappel for _, rappel in avant.boutons[0]] == ["alg:j:1", "alg:j:3", "alg:j:7"]

    allegement.repondre(_id("thomas"), "j", "3")
    apres = allegement.ecran(_id("thomas"))

    assert apres.texte.startswith("Tu es en mode allégé jusqu'à ")
    assert ("Arrêter", "alg:stop:0") in apres.boutons[-1]


def test_le_journal_dit_qui_s_est_allege(place):
    with operation.ouvrir("bot : /allege", acteur="thomas"):
        allegement.activer(_id("thomas"), 3)

    texte = journal.raconter("allégé")

    assert "Mode allégé pour Thomas : du " in texte
    assert "/allege" in texte


