"""Faire ceci vaut avoir fait cela.

Vider entièrement la litière rend le ramassage des crottes sans objet. Sans
cette règle, les deux tâches tombent le même jour et le système demande deux
fois le même geste.
"""

from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo

from tests.test_ensemble import sql

PARIS = ZoneInfo("Europe/Paris")


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


def pour_aujourd_hui(occurrence: dict) -> None:
    """Pose l'occurrence aujourd'hui, sur la journée.

    Seule une occurrence couverte due le jour de la validation, ou avant, est
    soldée ; une plus lointaine est retirée et repart du jour de la validation.
    Or le placement sépare parfois les deux tâches d'un jour : un samedi, il met
    le ramassage au dimanche. Sans cela, le test dépendrait du jour où il tourne.
    """
    sql("""UPDATE occurrence
              SET fenetre = tstzrange(debut_jour(jour_de(now())), upper(fenetre), '[)'),
                  creneau = tstzrange(debut_jour(jour_de(now())),
                                      debut_jour(jour_de(now()) + 1), '[)')
            WHERE id_occurrence = %s""", occurrence["id_occurrence"])


def test_vider_la_litiere_solde_aussi_le_ramassage(client, thomas):
    client.post("/planning/placer", headers=thomas)

    vidage = en_cours(client, thomas, "LITIERE_VIDAGE")
    ramassage_avant = en_cours(client, thomas, "LITIERE_CROTTES")
    pour_aujourd_hui(ramassage_avant)

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


# ---------------------------------------------------------------------------
# L'eau de Sassy : le même schéma que la litière
# ---------------------------------------------------------------------------

def test_l_eau_de_sassy_suit_le_rythme_de_la_litiere(client, thomas):
    client.post("/planning/placer", headers=thomas)

    eau = en_cours(client, thomas, "EAU_SASSY")
    fontaine = en_cours(client, thomas, "FONTAINE_SASSY")

    # Jamais faites : les deux sont dues dès aujourd'hui, l'eau sous deux
    # jours, la fontaine sous la semaine.
    # En jours de Paris : une fenêtre qui passe l'heure d'hiver dure une heure
    # de plus en temps universel, sans être plus longue d'un jour.
    for occurrence, jours in ((eau, 2), (fontaine, 7)):
        ouverture = datetime.fromisoformat(occurrence["echeance_min"]).astimezone(PARIS)
        cloture = datetime.fromisoformat(occurrence["echeance_max"]).astimezone(PARIS)
        ecart = cloture.replace(tzinfo=None) - ouverture.replace(tzinfo=None)
        assert timedelta(days=jours - 1) < ecart <= timedelta(days=jours + 1)


def test_laver_la_fontaine_vaut_changer_l_eau(client, thomas):
    client.post("/planning/placer", headers=thomas)

    fontaine = en_cours(client, thomas, "FONTAINE_SASSY")
    eau_avant = en_cours(client, thomas, "EAU_SASSY")
    pour_aujourd_hui(eau_avant)

    client.post(f"/occurrences/{fontaine['id_occurrence']}/valider",
                headers=thomas, json={})

    ancienne = next(o for o in occurrences(client, thomas, "EAU_SASSY")
                    if o["id_occurrence"] == eau_avant["id_occurrence"])
    assert ancienne["statut"] == "faite"
    assert "FONTAINE_SASSY" in ancienne["motif"]

    # Et le prochain changement d'eau repart du jour du lavage.
    suivant = en_cours(client, thomas, "EAU_SASSY")
    debut = datetime.fromisoformat(suivant["echeance_min"])
    assert debut >= datetime.now(UTC) + timedelta(days=1)


def test_changer_l_eau_ne_dispense_pas_de_laver_la_fontaine(client, thomas):
    client.post("/planning/placer", headers=thomas)

    eau = en_cours(client, thomas, "EAU_SASSY")
    fontaine_avant = en_cours(client, thomas, "FONTAINE_SASSY")

    client.post(f"/occurrences/{eau['id_occurrence']}/valider",
                headers=thomas, json={})

    fontaine_apres = en_cours(client, thomas, "FONTAINE_SASSY")
    assert fontaine_apres["id_occurrence"] == fontaine_avant["id_occurrence"]
    assert fontaine_apres["statut"] != "faite"
