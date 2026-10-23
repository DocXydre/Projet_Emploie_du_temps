"""Qui fait quoi, et ce qui se passe quand l'autre s'en charge.

Trois règles cohabitent ici, et elles se marchent volontiers dessus.

Le roulement d'abord (PLA-12) : à deux, une répartition qui ne regarde que la
charge du moment donne toujours la même tâche à la même personne, parce qu'à
charges égales il faut bien trancher et que le tri tranche toujours pareil. On
alterne donc, tant que l'écart de charge reste raisonnable.

Le coup de main ensuite (EXE-14) : la vaisselle est faite par qui passe devant.
Celui qui coche est celui qui l'a faite, et la tâche lui est recréditée.

L'avance enfin (EXE-15) : une tâche faite avant l'heure décale la suivante, et
le planning se refait aussitôt plutôt que d'attendre la nuit.
"""

from datetime import UTC, datetime, timedelta

import psycopg
import pytest

from api import conversation as conv
from tests.conftest import CLE_LORETTE, CLE_THOMAS, _url


def _sql(requete: str, *parametres):
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row,
                         autocommit=True) as conn:
        curseur = conn.execute(requete, parametres or None)
        return curseur.fetchall() if curseur.description else []


def _un(requete: str, *parametres):
    lignes = _sql(requete, *parametres)
    return next(iter(lignes[0].values())) if lignes else None


def _id(pseudo: str) -> int:
    return _un("SELECT id_utilisateur FROM utilisateur WHERE pseudo = %s", pseudo)


def _suite(code: str) -> list[str]:
    """Les assignés des occurrences d'une tâche, dans l'ordre des échéances."""
    return [ligne["pseudo"] for ligne in _sql(
        """
        SELECT u.pseudo
          FROM occurrence o
          JOIN tache t ON t.id_tache = o.id_tache
          LEFT JOIN utilisateur u ON u.id_utilisateur = o.id_utilisateur
         WHERE t.code = %s AND o.statut IN ('planifiee', 'notifiee')
         ORDER BY upper(o.fenetre)
        """, code)]


@pytest.fixture
def place(client, thomas):
    client.post("/planning/placer", headers=thomas)


# ---------------------------------------------------------------------------
# Le roulement                                                          PLA-12
# ---------------------------------------------------------------------------

def test_une_tache_ne_reste_pas_du_meme_cote(client, thomas, place):
    suite = _suite("LITIERE_CROTTES")

    assert len(suite) >= 4, "il faut plusieurs occurrences pour juger d'un roulement"
    assert len(set(suite)) == 2, f"toujours la même personne : {suite}"


def test_le_tour_evite_celui_qui_vient_de_l_avoir(client, thomas, place):
    # Sur une tâche fréquente, deux occurrences qui se suivent ne reviennent
    # pas à la même personne : c'est tout l'objet de l'alternance.
    suite = _suite("LITIERE_CROTTES")

    doublons = [i for i in range(1, len(suite)) if suite[i] == suite[i - 1]]
    assert not doublons, f"deux fois d'affilée pour la même personne : {suite}"


def test_le_pliage_du_linge_reste_a_lorette(client, thomas, base):
    # ABS-2 : une assignation fixée n'entre pas dans le roulement. Le pliage
    # naît d'un enchaînement, pas d'une récurrence : on interroge donc la règle
    # elle-même plutôt que d'attendre qu'une occurrence existe.
    tache = _un("SELECT id_tache FROM tache WHERE code = 'PLIER_LINGE'")

    for _ in range(3):
        assert _un("SELECT choisir_assigne(%s, "
                   "       tstzrange(now(), now() + INTERVAL '2 days'))",
                   tache) == _id("lorette")


def test_le_roulement_cede_devant_un_gros_desequilibre(client, thomas, base):
    """La balance reprend la main quand le tour coûte trop cher.

    Lorette croule sous les tâches : c'est son tour, mais lui en donner une de
    plus serait absurde. Au-delà d'une heure d'écart, la charge l'emporte.
    """
    elle, moi = _id("lorette"), _id("thomas")
    tache = _un("SELECT id_tache FROM tache WHERE code = 'ASPIRATEUR'")
    recurage = _un("SELECT id_tache FROM tache WHERE code = 'RECURAGE'")

    # Une heure et demie de récurage déjà sur le dos de Lorette.
    for _ in range(6):
        _sql("INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, statut, origine) "
             "VALUES (%s, %s, tstzrange(now(), now() + INTERVAL '2 days'), "
             "        'a_placer', 'manuelle')", recurage, elle)
    # Et c'est pourtant Thomas qui a passé l'aspirateur en dernier.
    _sql("INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, statut, origine, "
         "                        date_faite) "
         "VALUES (%s, %s, tstzrange(now() - INTERVAL '1 day', now()), 'faite', "
         "        'manuelle', now())", tache, moi)

    choisi = _un("SELECT choisir_assigne(%s, tstzrange(now(), now() + INTERVAL '2 days'))",
                 tache)

    assert choisi == moi


# ---------------------------------------------------------------------------
# Le coup de main                                                       EXE-14
# ---------------------------------------------------------------------------

def test_declarer_une_tache_prevue_pour_l_autre(client, thomas, place):
    moi = _id("thomas")
    sienne = _sql(
        """
        SELECT o.id_occurrence, t.code
          FROM occurrence o
          JOIN tache t ON t.id_tache = o.id_tache
         WHERE o.id_utilisateur = %s AND o.statut IN ('planifiee', 'notifiee')
           AND t.categorie <> 'sport'
         ORDER BY upper(o.fenetre) LIMIT 1
        """, _id("lorette"))[0]

    conv.declarer_faite(moi, sienne["code"])

    apres = _sql("SELECT statut, id_utilisateur FROM occurrence WHERE id_occurrence = %s",
                 sienne["id_occurrence"])[0]
    # Sa tâche est faite, et c'est à moi qu'elle est comptée.
    assert apres["statut"] == "faite"
    assert apres["id_utilisateur"] == moi


def test_declarer_ne_laisse_pas_l_ancienne_ouverte(client, thomas, place):
    """Le défaut d'avant : sa tâche restait au planning, la mienne s'ajoutait."""
    code = "LAVE_VAISSELLE"
    ouvertes = len(_suite(code))

    conv.declarer_faite(_id("thomas"), code)

    assert ouvertes, "il faut une occurrence ouverte pour que le test ait un sens"
    assert _un("SELECT count(*) FROM occurrence o JOIN tache t USING (id_tache) "
               " WHERE t.code = %s AND o.statut = 'faite'", code) == 1
    # Celle qu'on vient de faire ne traîne plus dans le planning de personne.
    assert _un("SELECT count(*) FROM occurrence o JOIN tache t USING (id_tache) "
               " WHERE t.code = %s AND o.statut IN ('a_placer', 'planifiee', 'notifiee') "
               "   AND lower(o.fenetre) <= now()", code) == 0


def test_chacun_peut_cocher_la_tache_de_l_autre(client, thomas, lorette, place):
    a_moi = _sql(
        "SELECT o.id_occurrence FROM occurrence o JOIN tache t ON t.id_tache = o.id_tache "
        " WHERE o.id_utilisateur = %s AND o.statut IN ('planifiee', 'notifiee') "
        "   AND t.categorie <> 'sport' ORDER BY upper(o.fenetre) LIMIT 1", _id("thomas"))[0]

    reponse = conv.executer_action("valider", a_moi["id_occurrence"], _id("lorette"))

    assert "noté" in reponse
    assert _un("SELECT id_utilisateur FROM occurrence WHERE id_occurrence = %s",
               a_moi["id_occurrence"]) == _id("lorette")


def test_toutes_les_taches_sont_declarables(client, thomas):
    # Y compris le pliage du linge, qui revient à Lorette : on déclare ce qu'on
    # a fait, pas ce qu'on devait faire.
    codes = {t["code"] for t in conv.taches_declarables(_id("thomas"))}

    assert "PLIER_LINGE" in codes
    assert "SPORT" not in codes


# ---------------------------------------------------------------------------
# L'avance                                                              EXE-15
# ---------------------------------------------------------------------------

def test_faite_en_avance_la_suivante_repart_d_aujourd_hui(client, thomas, place):
    # La poussière est hebdomadaire. Faite aujourd'hui alors qu'elle était
    # prévue plus tard, la prochaine compte une semaine à partir d'aujourd'hui.
    code = "POUSSIERE"
    debut_avant = _un(
        "SELECT min(lower(o.fenetre)) FROM occurrence o JOIN tache t USING (id_tache) "
        " WHERE t.code = %s AND o.statut IN ('planifiee', 'notifiee')", code)

    conv.declarer_faite(_id("thomas"), code)

    debut_apres = _un(
        "SELECT min(lower(o.fenetre)) FROM occurrence o JOIN tache t USING (id_tache) "
        " WHERE t.code = %s AND o.statut IN ('a_placer', 'planifiee', 'notifiee')", code)

    assert debut_apres > debut_avant
    assert debut_apres >= datetime.now(UTC) + timedelta(days=6)


def _prochaine(code: str) -> dict:
    return _sql(
        "SELECT o.statut, o.creneau FROM occurrence o JOIN tache t USING (id_tache) "
        " WHERE t.code = %s AND o.statut IN ('a_placer', 'planifiee', 'notifiee') "
        " ORDER BY lower(o.fenetre) LIMIT 1", code)[0]


def test_le_planning_se_refait_dans_la_foulee(client, thomas, place):
    conv.declarer_faite(_id("thomas"), "LITIERE_CROTTES")

    # Sans replacement, la suivante resterait « à placer » jusqu'à la nuit.
    assert _prochaine("LITIERE_CROTTES")["creneau"] is not None


def test_valider_par_l_api_replace_aussi(client, thomas, place):
    assert CLE_THOMAS and CLE_LORETTE  # les deux comptes existent bien

    occurrence = next(o for o in client.get("/occurrences", headers=thomas).json()
                      if o["tache_code"] == "LITIERE_CROTTES")
    client.post(f"/occurrences/{occurrence['id_occurrence']}/valider",
                headers=thomas, json={})

    assert _prochaine("LITIERE_CROTTES")["creneau"] is not None


# ---------------------------------------------------------------------------
# Les deux tâches ajoutées                                              TAC-11
# ---------------------------------------------------------------------------

def test_les_poubelles_et_les_draps_tournent(client, thomas, place):
    poubelles = _suite("POUBELLES")
    draps = _suite("DRAPS")

    # Tous les quatre jours sur cinq semaines : une bonne poignée d'occurrences.
    assert len(poubelles) >= 5
    assert len(set(poubelles)) == 2, f"toujours la même personne : {poubelles}"
    # Toutes les deux semaines : deux ou trois sur l'horizon.
    assert draps
    assert _un("SELECT reportable FROM tache WHERE code = 'DRAPS'") is True
    # Les poubelles ne se remettent pas à demain, elles.
    assert _un("SELECT reportable FROM tache WHERE code = 'POUBELLES'") is False


# ---------------------------------------------------------------------------
# Le coup de main se dit                                       EXE-16, PLA-13
# ---------------------------------------------------------------------------

def _alertes(pseudo: str) -> list[str]:
    return [ligne["contenu"] for ligne in _sql(
        "SELECT n.contenu FROM notification n JOIN utilisateur u USING (id_utilisateur) "
        " WHERE u.pseudo = %s AND n.type = 'alerte' ORDER BY n.id_notification", pseudo)]


def _sienne(pseudo: str) -> dict:
    """La prochaine tâche ménagère prévue pour quelqu'un."""
    return _sql(
        """
        SELECT o.id_occurrence, t.code
          FROM occurrence o
          JOIN tache t ON t.id_tache = o.id_tache
          JOIN utilisateur u ON u.id_utilisateur = o.id_utilisateur
         WHERE u.pseudo = %s AND o.statut IN ('planifiee', 'notifiee')
           AND t.categorie <> 'sport'
         ORDER BY upper(o.fenetre) LIMIT 1
        """, pseudo)[0]


def test_faire_la_tache_de_l_autre_le_lui_dit(client, thomas, place):
    sienne = _sienne("lorette")

    conv.executer_action("valider", sienne["id_occurrence"], _id("thomas"))

    alertes = _alertes("lorette")
    assert len(alertes) == 1
    assert "Thomas a fait" in alertes[0]
    # Et elle sait pourquoi la tâche a disparu de sa liste.
    assert "quitte ta liste" in alertes[0]


def test_faire_sa_propre_tache_ne_previent_personne(client, thomas, place):
    mienne = _sienne("thomas")

    conv.executer_action("valider", mienne["id_occurrence"], _id("thomas"))

    assert _alertes("lorette") == []


def test_celui_qui_coche_sait_qu_il_a_depanne(client, thomas, place):
    sienne = _sienne("lorette")

    reponse = conv.executer_action("valider", sienne["id_occurrence"], _id("thomas"))

    assert "Lorette" in reponse
    assert "rééquilibre" in reponse


def test_le_rappel_en_attente_part_avec_la_tache(client, thomas, place):
    sienne = _sienne("lorette")
    _sql("INSERT INTO notification (id_utilisateur, id_occurrence, type, contenu) "
         "VALUES (%s, %s, 'rappel', 'À faire aujourd''hui')",
         _id("lorette"), sienne["id_occurrence"])

    conv.executer_action("valider", sienne["id_occurrence"], _id("thomas"))

    # Demander de faire ce qui est fait est le genre de message qui fait couper
    # les notifications.
    assert _un("SELECT count(*) FROM notification WHERE id_occurrence = %s "
               "   AND type = 'rappel'", sienne["id_occurrence"]) == 0


def test_la_semaine_se_reequilibre_apres_une_reprise(client, thomas, place):
    avant = _un("SELECT charge_domestique(%s)", _id("lorette"))
    sienne = _sienne("lorette")

    conv.executer_action("valider", sienne["id_occurrence"], _id("thomas"))

    apres = _un("SELECT charge_domestique(%s)", _id("lorette"))
    # Elle n'a pas simplement perdu une tâche : la suite a été redistribuée,
    # donc elle en reprend. Sa charge ne s'effondre pas.
    assert apres >= avant - 60
    # Et rien n'est resté en plan : ce qui a été libéré a été replacé.
    assert _un("SELECT count(*) FROM occurrence WHERE statut = 'a_placer' "
               "   AND id_utilisateur IS NULL "
               "   AND lower(fenetre) < now() + INTERVAL '7 days'") == 0


def test_une_tache_deja_annoncee_ne_bouge_pas(client, thomas, place):
    a_elle = _sienne("lorette")
    _sql("INSERT INTO notification (id_utilisateur, id_occurrence, type, contenu, "
         "                           statut, date_envoi) "
         "VALUES (%s, %s, 'rappel', 'Prévu ce soir', 'envoyee', now())",
         _id("lorette"), a_elle["id_occurrence"])
    autre = _sql(
        """
        SELECT o.id_occurrence FROM occurrence o JOIN tache t USING (id_tache)
          JOIN utilisateur u ON u.id_utilisateur = o.id_utilisateur
         WHERE u.pseudo = 'thomas' AND o.statut = 'planifiee'
           AND t.categorie <> 'sport' ORDER BY upper(o.fenetre) LIMIT 1
        """)[0]

    conv.executer_action("valider", autre["id_occurrence"], _id("lorette"))

    # Ce qu'on a lu le matin ne disparaît pas de la liste l'après-midi.
    assert _un("SELECT id_utilisateur FROM occurrence WHERE id_occurrence = %s",
               a_elle["id_occurrence"]) == _id("lorette")


def test_le_pliage_reste_a_lorette_meme_apres_un_reequilibrage(client, thomas, place):
    sienne = _sienne("lorette")

    conv.executer_action("valider", sienne["id_occurrence"], _id("thomas"))

    # ABS-2 : la redistribution ne touche pas à une assignation fixée.
    assignes = {ligne["pseudo"] for ligne in _sql(
        """
        SELECT u.pseudo FROM occurrence o JOIN tache t USING (id_tache)
          JOIN utilisateur u ON u.id_utilisateur = o.id_utilisateur
         WHERE t.code = 'PLIER_LINGE' AND o.statut IN ('planifiee', 'notifiee')
        """)}
    assert assignes in ({"lorette"}, set())
