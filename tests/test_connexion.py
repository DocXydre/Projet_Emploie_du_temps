"""Se connecter depuis l'appli avec un mot de passe              (CNX-1 à CNX-4)"""

from api import mot_de_passe
from tests.test_ensemble import _id, un


def test_le_mot_de_passe_rend_la_cle_et_n_est_jamais_stocke(client, thomas):
    choix = client.put("/mot-de-passe", headers=thomas,
                       json={"mot_de_passe": "une phrase assez longue"})
    assert choix.status_code == 200
    stocke = un("SELECT mot_de_passe FROM utilisateur WHERE pseudo = 'thomas'")
    assert stocke.startswith("scrypt$") and "longue" not in stocke

    rendu = client.post("/connexion", json={"pseudo": "Thomas",
                                            "mot_de_passe": "une phrase assez longue"})
    assert rendu.status_code == 200
    assert rendu.json()["cle_api"] == thomas["X-Cle-Api"]
    # La clé rendue ouvre l'API comme avant.
    assert client.get("/exercices", headers={"X-Cle-Api": rendu.json()["cle_api"]}
                      ).status_code == 200


def test_un_mauvais_mot_de_passe_ne_dit_rien_et_cinq_echecs_bloquent(client, thomas):
    mot_de_passe.choisir(_id("thomas"), "le bon mot de passe")
    inconnu = client.post("/connexion", json={"pseudo": "personne", "mot_de_passe": "x"})
    mauvais = client.post("/connexion", json={"pseudo": "thomas", "mot_de_passe": "x"})
    assert inconnu.status_code == mauvais.status_code == 401
    assert inconnu.json()["message"] == mauvais.json()["message"]

    for _ in range(4):
        client.post("/connexion", json={"pseudo": "thomas", "mot_de_passe": "faux"})
    bloque = client.post("/connexion", json={"pseudo": "thomas",
                                             "mot_de_passe": "le bon mot de passe"})
    assert bloque.status_code == 429

    # Choisir un nouveau mot de passe débloque le compte.
    mot_de_passe.choisir(_id("thomas"), "le bon mot de passe")
    assert client.post("/connexion", json={"pseudo": "thomas",
                                           "mot_de_passe": "le bon mot de passe"}
                       ).status_code == 200


def test_un_compte_sans_mot_de_passe_ne_se_connecte_pas(client, thomas):
    assert client.post("/connexion", json={"pseudo": "thomas", "mot_de_passe": ""}
                       ).status_code == 422
    assert client.post("/connexion", json={"pseudo": "thomas", "mot_de_passe": "abc"}
                       ).status_code == 401


def test_un_mot_de_passe_trop_court_est_refuse(client, thomas):
    refus = client.put("/mot-de-passe", headers=thomas, json={"mot_de_passe": "court"})
    assert refus.status_code == 422 and "10 caractères" in refus.json()["message"]
