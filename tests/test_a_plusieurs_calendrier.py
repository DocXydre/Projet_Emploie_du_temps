"""Les tâches à plusieurs : le calendrier (lot B2)"""

from api.calendrier import _identifiant


def test_deux_participants_ont_deux_identifiants():
    assert _identifiant({"nature": "tache", "id": 7, "id_utilisateur": 1}) != _identifiant(
        {"nature": "tache", "id": 7, "id_utilisateur": 2}
    )


def test_l_identifiant_d_une_tache_est_stable():
    assert (
        _identifiant({"nature": "tache", "id": 7, "id_utilisateur": 1}) == "tache-7-1@planif.local"
    )


def test_une_occupation_garde_son_identifiant():
    assert (
        _identifiant({"nature": "occupation", "id": 7, "id_utilisateur": 1})
        == "occupation-7@planif.local"
    )
