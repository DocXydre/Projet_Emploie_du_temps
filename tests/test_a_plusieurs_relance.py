"""Les tâches à plusieurs : la relance du soir (lot B2)"""

from tests.test_ensemble import _id, sql, un
from tests.test_regles import _nouvelle, _regle

FAIT = "Nettoyer la hotte : c'est fait ?"


def _ce_soir(a_deux: bool) -> int:
    """« Nettoyer la hotte », annoncée ('notifiee') aujourd'hui de 10h à 11h, à Thomas."""
    t = _nouvelle()
    if a_deux:
        _regle(t)
    numero = un(
        "INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, creneau, statut, origine, "
        "rappel_journee) "
        "VALUES (%s, %s, "
        "tstzrange(debut_jour(jour_de(now())), debut_jour(jour_de(now()) + 1), '[)'), "
        "tstzrange(debut_jour(jour_de(now())) + INTERVAL '10 hours', "
        "debut_jour(jour_de(now())) + INTERVAL '11 hours', '[)'), "
        "'notifiee', 'manuelle', FALSE) RETURNING id_occurrence",
        t,
        _id("thomas"),
    )
    if a_deux:
        sql(
            "INSERT INTO occurrence_participant (id_occurrence, id_utilisateur) "
            "VALUES (%s, %s), (%s, %s)",
            numero,
            _id("thomas"),
            numero,
            _id("lorette"),
        )
    return numero


def _rappels(numero: int) -> list[tuple]:
    return [
        (ligne["id_utilisateur"], ligne["contenu"])
        for ligne in sql(
            "SELECT id_utilisateur, contenu FROM notification "
            "WHERE id_occurrence = %s AND type = 'rappel' ORDER BY id_utilisateur",
            numero,
        )
    ]


def test_la_relance_part_aux_deux_participants(base):
    numero = _ce_soir(True)
    assert un("SELECT relance_du_soir_de(NULL)") == 2
    assert _rappels(numero) == sorted([(_id("thomas"), FAIT), (_id("lorette"), FAIT)])


def test_une_seule_relance_par_participant_et_par_soir(base):
    numero = _ce_soir(True)
    assert un("SELECT relance_du_soir_de(NULL)") == 2
    assert un("SELECT relance_du_soir_de(NULL)") == 0
    assert len(_rappels(numero)) == 2


def test_la_relance_d_un_compte_ne_part_qu_a_lui(base):
    numero = _ce_soir(True)
    assert un("SELECT relance_du_soir_de(%s)", _id("lorette")) == 1
    assert _rappels(numero) == [(_id("lorette"), FAIT)]
    assert un("SELECT relance_du_soir_de(%s)", _id("thomas")) == 1
    assert len(_rappels(numero)) == 2


def test_une_tache_ordinaire_n_est_relancee_qu_a_son_assigne(base):
    numero = _ce_soir(False)
    assert un("SELECT relance_du_soir_de(%s)", _id("lorette")) == 0
    assert un("SELECT relance_du_soir_de(NULL)") == 1
    assert _rappels(numero) == [(_id("thomas"), FAIT)]
