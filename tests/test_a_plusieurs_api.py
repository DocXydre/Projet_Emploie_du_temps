"""Les tâches à plusieurs : l'API des occurrences (lot B2)"""

from tests.test_ensemble import _id, sql, un
from tests.test_regles import _nouvelle, _regle

A_VENIR = "tstzrange(now(), now() + INTERVAL '3 days', '[)')"
EN_RETARD = "tstzrange(now() - INTERVAL '3 days', now() - INTERVAL '1 day', '[)')"


def _occurrence(a_deux: bool, fenetre: str = A_VENIR) -> int:
    t = _nouvelle()
    if a_deux:
        _regle(t)
    numero = un(
        "INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, origine) "
        f"VALUES (%s, %s, {fenetre}, 'manuelle') RETURNING id_occurrence",
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


def _ligne(lignes: list[dict], numero: int) -> dict:
    return next(ligne for ligne in lignes if ligne["id_occurrence"] == numero)


def test_le_detail_donne_les_participants(client, thomas):
    numero = _occurrence(True)
    reponse = client.get(f"/occurrences/{numero}", headers=thomas)
    assert reponse.status_code == 200
    assert sorted(reponse.json()["participants"]) == ["lorette", "thomas"]


def test_une_tache_ordinaire_a_une_liste_vide(client, thomas):
    numero = _occurrence(False)
    assert client.get(f"/occurrences/{numero}", headers=thomas).json()["participants"] == []


def test_la_liste_donne_les_participants(client, thomas):
    numero = _occurrence(True)
    lignes = client.get("/occurrences", headers=thomas).json()
    assert sorted(_ligne(lignes, numero)["participants"]) == ["lorette", "thomas"]


def test_les_taches_en_retard_donnent_les_participants(client, thomas):
    numero = _occurrence(True, EN_RETARD)
    lignes = client.get("/occurrences/en-retard", headers=thomas).json()
    assert sorted(_ligne(lignes, numero)["participants"]) == ["lorette", "thomas"]
