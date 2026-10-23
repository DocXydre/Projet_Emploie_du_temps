"""Ce que l'appli Coach Santé (ios/CoachSante) envoie, tel qu'elle l'envoie.

Les corps ci-dessous recopient ceux que fabriquent `JourSante.corps` et
`SeanceMontre.corps` dans `LecteurSante.swift` : si l'un change, l'autre suit.
"""

# ruff: noqa: F811 (les fixtures de test_coach sont importées puis demandées)

import uuid
from datetime import datetime, timedelta

from api.coach.clair import aujourd_hui
from tests.test_coach import u  # noqa: F401
from tests.test_ensemble import PARIS, sql, un


def test_un_jour_tel_que_l_appli_l_envoie(client, thomas, u):
    hier = (aujourd_hui() - timedelta(days=1)).isoformat()
    corps = {"pas": 8412, "fc_repos": 52, "vfc_ms": 61.4, "sommeil_minutes": 437}

    rendu = client.put(f"/donnees-sante/jours/{hier}", json=corps, headers=thomas)
    assert rendu.status_code == 200, rendu.text

    # Renvoyé, il met à jour sans doublon. Une valeur absente reste absente.
    rendu = client.put(f"/donnees-sante/jours/{hier}", json={"pas": 9000}, headers=thomas)
    assert rendu.status_code == 200, rendu.text
    ligne = sql("SELECT pas, fc_repos, sommeil_minutes FROM sante_jour WHERE id_utilisateur = %s",
                u)
    assert len(ligne) == 1 and ligne[0]["pas"] == 9000


def test_une_seance_de_la_montre_telle_que_l_appli_l_envoie(client, thomas, u):
    debut = datetime.now(PARIS).replace(microsecond=0) - timedelta(hours=3)
    fin = debut + timedelta(minutes=42)
    cle = str(uuid.uuid4()).upper()
    corps = {
        "type": "running",
        "debut": debut.isoformat(),
        "fin": fin.isoformat(),
        "duree_secondes": 2520,
        "distance_m": 7012,
        "denivele_m": 35,
        "energie_kcal": 498,
        "fc_moyenne": 151,
        "fc_max": 178,
        "allure_s_km": 359,
        "cadence": 168,
        "details": {"interieur": False, "source": "Apple Watch de Thomas",
                    "type_healthkit": 37, "appareil": "Watch", "temperature_c": 14.5},
    }

    rendu = client.put(f"/donnees-sante/activites/{cle}", json=corps, headers=thomas)
    assert rendu.status_code == 200, rendu.text
    assert rendu.json()["discipline"] == "course"
    assert client.put(f"/donnees-sante/activites/{cle}", json=corps,
                      headers=thomas).status_code == 200
    assert un("SELECT count(*) FROM activite_sante WHERE id_utilisateur = %s", u) == 1
    assert un("SELECT details ->> 'source' FROM activite_sante") == "Apple Watch de Thomas"

    fraicheur = client.get("/donnees-sante/fraicheur", headers=thomas)
    assert fraicheur.status_code == 200 and fraicheur.json()["dernier_envoi"]


def test_les_types_de_l_appli_tombent_dans_la_bonne_discipline():
    from api.coach.sante import discipline_de
    attendu = {"running": "course", "traditionalStrengthTraining": "musculation",
               "functionalStrengthTraining": "musculation", "coreTraining": "musculation",
               "elliptical": "cardio", "rowing": "cardio", "stepper": "cardio",
               "indoorCycling": "cardio", "highIntensityIntervalTraining": "cardio",
               "cycling": "autre", "swimming": "autre", "walking": "autre", "autre_3000": "autre"}
    assert {t: discipline_de(t) for t in attendu} == attendu


def test_un_refus_a_un_motif_que_l_appli_sait_lire(client, thomas, u):
    demain = (aujourd_hui() + timedelta(days=1)).isoformat()
    rendu = client.put(f"/donnees-sante/jours/{demain}", json={"pas": 1}, headers=thomas)
    assert rendu.status_code >= 400
    corps = rendu.json()
    # L'appli lit « message », « detail.message », « detail » ou la liste de pydantic.
    assert "message" in corps or "detail" in corps


def test_l_historique_ne_remplit_pas_le_planning_passe(client, thomas, u):
    # SAN-8 : une séance de la montre de plus de 28 jours est gardée, sans
    # devenir une séance libre. Une récente, elle, en devient une.
    for jours, cle in ((90, "ANCIENNE"), (2, "RECENTE")):
        debut = datetime.now(PARIS).replace(microsecond=0) - timedelta(days=jours)
        corps = {"type": "traditionalStrengthTraining", "debut": debut.isoformat(),
                 "fin": (debut + timedelta(minutes=50)).isoformat(),
                 "duree_secondes": 3000, "details": {}}
        rendu = client.put(f"/donnees-sante/activites/{cle}", json=corps, headers=thomas)
        assert rendu.status_code == 200, rendu.text

    rattachees = {r["cle_externe"]: r["id_occurrence"] for r in sql(
        "SELECT cle_externe, id_occurrence FROM activite_sante WHERE id_utilisateur = %s", u)}
    assert rattachees["ANCIENNE"] is None and rattachees["RECENTE"] is not None
