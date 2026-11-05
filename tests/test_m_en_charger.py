"""« Je m'en charge » : prendre une tâche sans la valider            (EXE-18)

La tâche change de mains et s'épingle à celui qui la prend ; elle reste à
faire. L'ancien assigné est prévenu. Ces tests appellent la fonction SQL ; la
route est testée dans test_repartition.py.
"""

import psycopg
import pytest

from tests.conftest import _url


def _sql(requete: str, *parametres):
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row, autocommit=True) as conn:
        curseur = conn.execute(requete, parametres or None)
        return curseur.fetchall() if curseur.description else []


def _un(requete: str, *parametres):
    lignes = _sql(requete, *parametres)
    return next(iter(lignes[0].values())) if lignes else None


def _id(pseudo: str) -> int:
    return _un("SELECT id_utilisateur FROM utilisateur WHERE pseudo = %s", pseudo)


def _occurrence(pour: str | None, debut: int = 0, fin: int = 3, statut: str = "a_placer") -> int:
    """Une occurrence de « Nettoyer la hotte » pour `pour` (None : personne), dont la
    fenêtre va de `debut` à `fin` jours depuis maintenant ; négatifs, elle est en retard."""
    tache = _un(
        "SELECT creer_tache(p_libelle => 'Nettoyer la hotte', p_acteur => %s, "
        "p_tous_les_jours => 14, p_duree_minutes => 30)",
        _id("thomas"),
    )
    creneau = (
        "tstzrange(now() + INTERVAL '1 day', now() + INTERVAL '1 day 30 minutes', '[)')"
        if statut == "planifiee"
        else "NULL"
    )
    return _un(
        "INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, creneau, statut, origine) "
        "VALUES (%s, %s, tstzrange(now() + make_interval(days => %s), "
        f"now() + make_interval(days => %s), '[)'), {creneau}, %s, 'manuelle') "
        "RETURNING id_occurrence",
        tache,
        _id(pour) if pour else None,
        debut,
        fin,
        statut,
    )


def _etat(numero: int) -> list[dict]:
    return _sql(
        "SELECT id_utilisateur, epinglee, statut FROM occurrence WHERE id_occurrence = %s", numero
    )


def _refuse(numero: int, motif: str) -> None:
    avant = _etat(numero)
    with pytest.raises(psycopg.errors.CheckViolation, match=motif):
        _sql("SELECT m_en_charger(%s, %s)", numero, _id("thomas"))
    assert _etat(numero) == avant


def test_prendre_la_tache_de_l_autre_la_donne_et_l_epingle():
    thomas, lorette = _id("thomas"), _id("lorette")
    numero = _occurrence("lorette", statut="planifiee")
    _sql(
        "INSERT INTO notification (id_utilisateur, id_occurrence, type, contenu) "
        "VALUES (%s, %s, 'rappel', 'Nettoyer la hotte, demain')",
        lorette,
        numero,
    )

    assert _un("SELECT m_en_charger(%s, %s)", numero, thomas) == numero

    ligne = _sql(
        "SELECT id_utilisateur, epinglee, epinglee_par, statut, date_faite "
        "FROM occurrence WHERE id_occurrence = %s",
        numero,
    )[0]
    assert ligne == {
        "id_utilisateur": thomas,
        "epinglee": True,
        "epinglee_par": "admin",
        "statut": "planifiee",
        "date_faite": None,
    }
    # Lorette est prévenue (une alerte qui nomme la tâche et Thomas), et le
    # rappel qui l'attendait est parti.
    messages = _sql(
        "SELECT type, statut, contenu FROM notification "
        "WHERE id_utilisateur = %s AND id_occurrence = %s",
        lorette,
        numero,
    )
    assert len(messages) == 1
    assert messages[0]["type"] == "alerte" and messages[0]["statut"] == "a_envoyer"
    assert "Thomas" in messages[0]["contenu"] and "Nettoyer la hotte" in messages[0]["contenu"]


def test_la_tache_prise_ne_bouge_plus_a_la_repartition():
    """PLA-5, PLA-13 : épinglée, elle reste à celui qui l'a prise."""
    thomas = _id("thomas")
    numero = _occurrence("lorette", statut="planifiee")
    _un("SELECT m_en_charger(%s, %s)", numero, thomas)
    # Une tâche déjà annoncée n'est jamais libérée : sans cette ligne le test
    # passerait pour une autre raison que l'épingle.
    _sql("DELETE FROM notification")

    _sql("SELECT reequilibrer(7)")

    assert _etat(numero) == [{"id_utilisateur": thomas, "epinglee": True, "statut": "a_placer"}]


def test_la_tache_prise_quitte_le_creneau_de_l_autre_et_se_replace_pour_soi():
    """EXE-18 : épinglée à la personne, pas à l'heure choisie pour l'autre."""
    thomas = _id("thomas")
    numero = _occurrence("lorette", statut="planifiee")

    _un("SELECT m_en_charger(%s, %s)", numero, thomas)
    assert _un("SELECT creneau FROM occurrence WHERE id_occurrence = %s", numero) is None

    _sql("SELECT placer_taches()")
    assert _etat(numero) == [{"id_utilisateur": thomas, "epinglee": True, "statut": "planifiee"}]


def test_une_tache_en_retard_se_reprend_meme_si_elle_est_deja_a_soi():
    thomas = _id("thomas")
    numero = _occurrence("thomas", debut=-5, fin=-2)

    _un("SELECT m_en_charger(%s, %s)", numero, thomas)

    assert _etat(numero) == [{"id_utilisateur": thomas, "epinglee": True, "statut": "a_placer"}]
    assert _un("SELECT count(*) FROM notification WHERE id_occurrence = %s", numero) == 0


def test_une_tache_sans_assigne_se_prend_sans_prevenir_personne():
    thomas = _id("thomas")
    numero = _occurrence(None)

    _un("SELECT m_en_charger(%s, %s)", numero, thomas)

    assert _etat(numero) == [{"id_utilisateur": thomas, "epinglee": True, "statut": "a_placer"}]
    assert _un("SELECT count(*) FROM notification WHERE id_occurrence = %s", numero) == 0


def test_une_tache_faite_ne_se_prend_pas():
    numero = _occurrence("lorette")
    _sql("SELECT valider_occurrence(%s, %s, NULL)", numero, _id("lorette"))
    _refuse(numero, "déjà faite")


def test_une_tache_abandonnee_ne_se_prend_pas():
    _refuse(_occurrence("lorette", statut="abandonnee"), "abandonnée")


def test_une_tache_reportee_ne_se_prend_pas():
    _refuse(_occurrence("lorette", statut="reportee"), "reportée")


def test_une_seance_de_sport_ne_se_prend_pas():
    sql_query = (
        "INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, creneau, statut, origine, "
        "motif) "
        "SELECT id_tache, %s, tstzrange(now(), now() + INTERVAL '2 days', '[)'), "
        "tstzrange(now() + INTERVAL '1 hour', now() + INTERVAL '2 hours', '[)'), "
        "'planifiee', 'quota', 'À déterminer' FROM tache WHERE id_type_tache IS NULL "
        "RETURNING id_occurrence"
    )
    numero = _un(sql_query, _id("lorette"))
    _refuse(numero, "séance de sport")


def test_une_tache_a_plusieurs_ne_se_prend_pas():
    numero = _occurrence("lorette")
    _sql(
        "INSERT INTO occurrence_participant (id_occurrence, id_utilisateur) "
        "VALUES (%s, %s), (%s, %s)",
        numero,
        _id("thomas"),
        numero,
        _id("lorette"),
    )
    _refuse(numero, "à plusieurs")


def test_une_tache_deja_a_soi_et_pas_en_retard_ne_se_prend_pas():
    _refuse(_occurrence("thomas"), "déjà à toi")


def test_une_occurrence_inconnue_est_refusee():
    with pytest.raises(psycopg.errors.NoDataFound):
        _sql("SELECT m_en_charger(999999, %s)", _id("thomas"))
