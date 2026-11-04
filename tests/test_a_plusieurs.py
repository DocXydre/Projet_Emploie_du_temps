"""Les tâches à plusieurs : la base (lot B1)"""

import psycopg
import pytest

from tests.test_ensemble import _id, sql, un
from tests.test_regles import _nouvelle, _regle


def test_une_tache_sans_regle_n_est_pas_a_plusieurs(base):
    t = _nouvelle()
    assert un("SELECT membres_a_plusieurs(%s)", t) is None
    assert un("SELECT membres_a_plusieurs(999999)") is None


def test_la_regle_en_vigueur_donne_le_nombre_de_membres(base):
    t = _nouvelle()
    _regle(t)
    assert un("SELECT membres_a_plusieurs(%s)", t) == 2
    assert un("SELECT membres_a_plusieurs(essais.tache_de('GRAND_NETTOYAGE'))") == 2


def test_retirer_la_regle_rend_la_tache_ordinaire(base):
    t = _nouvelle()
    r = _regle(t)
    un("SELECT retirer_regle(%s)", r)
    assert un("SELECT membres_a_plusieurs(%s)", t) is None


def test_une_regle_remplacee_compte_une_fois(base):
    t = _nouvelle()
    _regle(t)
    _regle(t, phrase="À deux, toujours.")
    assert un("SELECT membres_a_plusieurs(%s)", t) == 2


def test_un_participant_ne_figure_qu_une_fois(base):
    t = _nouvelle()
    numero = un(
        "INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, origine) "
        "VALUES (%s, NULL, tstzrange(now(), now() + INTERVAL '3 days', '[)'), 'manuelle') "
        "RETURNING id_occurrence",
        t,
    )

    # Insert first participant
    un(
        "INSERT INTO occurrence_participant (id_occurrence, id_utilisateur) VALUES (%s, %s)",
        numero,
        _id("thomas"),
    )

    # Second insert with same occurrence and user should raise UniqueViolation
    with pytest.raises(psycopg.errors.UniqueViolation):
        un(
            "INSERT INTO occurrence_participant (id_occurrence, id_utilisateur) VALUES (%s, %s)",
            numero,
            _id("thomas"),
        )

    # Insert with different user should succeed
    un(
        "INSERT INTO occurrence_participant (id_occurrence, id_utilisateur) VALUES (%s, %s)",
        numero,
        _id("lorette"),
    )


def test_les_participants_partent_avec_leur_occurrence(base):
    t = _nouvelle()
    numero = un(
        "INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, origine) "
        "VALUES (%s, NULL, tstzrange(now(), now() + INTERVAL '3 days', '[)'), 'manuelle') "
        "RETURNING id_occurrence",
        t,
    )

    # Insert participants
    un(
        "INSERT INTO occurrence_participant (id_occurrence, id_utilisateur) VALUES (%s, %s)",
        numero,
        _id("thomas"),
    )
    un(
        "INSERT INTO occurrence_participant (id_occurrence, id_utilisateur) VALUES (%s, %s)",
        numero,
        _id("lorette"),
    )

    # Delete occurrence
    sql("DELETE FROM occurrence WHERE id_occurrence = %s", numero)

    # Participants should be gone too
    assert un("SELECT count(*) FROM occurrence_participant WHERE id_occurrence = %s", numero) == 0


def test_les_cles_etrangeres_sont_en_cascade(base):
    lignes = sql(
        "SELECT confrelid::regclass::text AS cible, confdeltype "
        "FROM pg_constraint WHERE conrelid = 'occurrence_participant'::regclass "
        "AND contype = 'f' ORDER BY 1"
    )
    assert [(ligne["cible"], ligne["confdeltype"]) for ligne in lignes] == [
        ("occurrence", "c"),
        ("utilisateur", "c"),
    ]
