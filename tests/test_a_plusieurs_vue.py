"""Les tâches à plusieurs : v_occurrence (lot B2)"""

from tests.test_ensemble import _id, sql, un
from tests.test_regles import _nouvelle, _regle

_OCCURRENCE = (
    "INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, origine) "
    "VALUES (%s, %s, {fenetre}, 'manuelle') RETURNING id_occurrence"
)
_A_VENIR = "tstzrange(now(), now() + INTERVAL '3 days', '[)')"
_PASSEE = "tstzrange(now() - INTERVAL '3 days', now() - INTERVAL '1 day', '[)')"


def _occurrence(tache: int, fenetre: str = _A_VENIR) -> int:
    return un(_OCCURRENCE.format(fenetre=fenetre), tache, _id("thomas"))


def _a_deux(fenetre: str = _A_VENIR) -> int:
    t = _nouvelle()
    _regle(t)
    numero = _occurrence(t, fenetre)
    sql(
        "INSERT INTO occurrence_participant (id_occurrence, id_utilisateur) "
        "VALUES (%s, %s), (%s, %s)",
        numero,
        _id("thomas"),
        numero,
        _id("lorette"),
    )
    return numero


# RGL-17 : la vue dit qui participe à une tâche à plusieurs.


def test_une_occurrence_a_deux_dit_ses_participants(base):
    numero = _a_deux()
    participants = un("SELECT participants FROM v_occurrence WHERE id_occurrence = %s", numero)
    assert sorted(participants) == ["lorette", "thomas"]


def test_une_occurrence_ordinaire_a_une_liste_vide(base):
    numero = _occurrence(_nouvelle())
    assert un("SELECT participants FROM v_occurrence WHERE id_occurrence = %s", numero) == []


def test_les_taches_en_retard_portent_aussi_les_participants(base):
    numero = _a_deux(_PASSEE)
    participants = un(
        "SELECT participants FROM v_taches_en_retard WHERE id_occurrence = %s", numero
    )
    assert sorted(participants) == ["lorette", "thomas"]
