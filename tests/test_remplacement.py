"""Faire ceci vaut avoir fait cela.

Vider entièrement la litière rend le ramassage des crottes sans objet. Sans
cette règle, les deux tâches tombent le même jour et le système demande deux
fois le même geste.
"""

from datetime import UTC, datetime, timedelta


def occurrences(client, thomas, code: str) -> list[dict]:
    toutes = client.get("/occurrences", headers=thomas,
                        params={"statut": ["a_placer", "planifiee", "notifiee",
                                           "faite", "reportee", "abandonnee"]}).json()
    return [o for o in toutes if o["tache_code"] == code]


def en_cours(client, thomas, code: str) -> dict:
    """La prochaine occurrence ouverte.

    Le planning est pré-généré sur un mois : une tâche fréquente a donc
    plusieurs occurrences ouvertes. Seule la plus proche nous intéresse.
    """
    ouvertes = [o for o in occurrences(client, thomas, code)
                if o["statut"] in ("a_placer", "planifiee", "notifiee")]
    assert ouvertes, f"aucune occurrence ouverte de {code}"
    return min(ouvertes, key=lambda o: o["echeance_min"])


def test_vider_la_litiere_solde_aussi_le_ramassage(client, thomas):
    client.post("/planning/placer", headers=thomas)

    vidage = en_cours(client, thomas, "LITIERE_VIDAGE")
    ramassage_avant = en_cours(client, thomas, "LITIERE_CROTTES")

    client.post(f"/occurrences/{vidage['id_occurrence']}/valider",
                headers=thomas, json={})

    # L'ancienne occurrence de ramassage est close, et son motif dit pourquoi.
    ancienne = next(o for o in occurrences(client, thomas, "LITIERE_CROTTES")
                    if o["id_occurrence"] == ramassage_avant["id_occurrence"])
    assert ancienne["statut"] == "faite"
    assert "LITIERE_VIDAGE" in ancienne["motif"]


def test_le_prochain_ramassage_repart_du_jour_du_vidage(client, thomas):
    client.post("/planning/placer", headers=thomas)
    vidage = en_cours(client, thomas, "LITIERE_VIDAGE")

    client.post(f"/occurrences/{vidage['id_occurrence']}/valider",
                headers=thomas, json={})

    # Le ramassage est tous les deux jours : la prochaine occurrence doit donc
    # tomber après-demain, et non aujourd'hui.
    suivant = en_cours(client, thomas, "LITIERE_CROTTES")
    debut = datetime.fromisoformat(suivant["echeance_min"])
    assert debut >= datetime.now(UTC) + timedelta(days=1)


def test_les_deux_taches_ne_tombent_plus_le_meme_jour(client, thomas):
    client.post("/planning/placer", headers=thomas)
    vidage = en_cours(client, thomas, "LITIERE_VIDAGE")

    client.post(f"/occurrences/{vidage['id_occurrence']}/valider",
                headers=thomas, json={})
    client.post("/planning/placer", headers=thomas)

    jour_vidage = en_cours(client, thomas, "LITIERE_VIDAGE")["debut"]
    jour_ramassage = en_cours(client, thomas, "LITIERE_CROTTES")["debut"]
    assert jour_vidage != jour_ramassage


def test_le_ramassage_ne_solde_pas_le_vidage(client, thomas):
    # La relation n'est pas symétrique : ramasser les crottes ne dispense pas
    # de vider la litière une fois par semaine.
    client.post("/planning/placer", headers=thomas)

    ramassage = en_cours(client, thomas, "LITIERE_CROTTES")
    vidage_avant = en_cours(client, thomas, "LITIERE_VIDAGE")

    client.post(f"/occurrences/{ramassage['id_occurrence']}/valider",
                headers=thomas, json={})

    vidage_apres = en_cours(client, thomas, "LITIERE_VIDAGE")
    assert vidage_apres["id_occurrence"] == vidage_avant["id_occurrence"]
    assert vidage_apres["statut"] != "faite"


def test_une_tache_sans_remplacement_n_est_pas_touchee(client, thomas):
    client.post("/planning/placer", headers=thomas)

    aspirateur_avant = en_cours(client, thomas, "ASPIRATEUR")
    vidage = en_cours(client, thomas, "LITIERE_VIDAGE")

    client.post(f"/occurrences/{vidage['id_occurrence']}/valider",
                headers=thomas, json={})

    aspirateur_apres = en_cours(client, thomas, "ASPIRATEUR")
    assert aspirateur_apres["id_occurrence"] == aspirateur_avant["id_occurrence"]
