"""Une clé par appareil, et aucune clé en clair                   (CNX-11, CNX-12)"""

import hashlib

import psycopg
import pytest

from api import appairage, mot_de_passe
from tests.conftest import CLE_LORETTE, CLE_THOMAS
from tests.test_ensemble import _id, sql, un

MOT_DE_PASSE = "une phrase assez longue"


def _empreinte(cle: str) -> str:
    return hashlib.sha256(cle.encode()).hexdigest()


def _connecter(client, pseudo: str = "thomas", appareil: str = "iPhone de test") -> dict:
    mot_de_passe.choisir(_id(pseudo), MOT_DE_PASSE)
    rendu = client.post("/connexion", json={"pseudo": pseudo, "mot_de_passe": MOT_DE_PASSE,
                                            "appareil": appareil})
    assert rendu.status_code == 200, rendu.text
    return {"X-Cle-Api": rendu.json()["cle_api"]}


def test_aucune_cle_de_compte_n_est_gardee_en_clair(client, thomas):
    assert un("SELECT count(*) FROM utilisateur WHERE cle_api IS NOT NULL") == 0
    assert un("SELECT empreinte_cle_api FROM utilisateur WHERE pseudo = 'thomas'") \
        == _empreinte(CLE_THOMAS)
    # La clé du compte ouvre toujours l'API : les iPhones connectés avant les
    # sessions l'ont dans leur trousseau.
    moi = client.get("/moi", headers=thomas).json()
    assert moi["pseudo"] == "thomas" and moi["id_session"] is None


def test_une_cle_ecrite_en_clair_est_hachee_a_l_ecriture(client, lorette):
    nouvelle = "N" * 48
    try:
        sql("UPDATE utilisateur SET cle_api = %s WHERE pseudo = 'lorette'", nouvelle)
        assert un("SELECT cle_api FROM utilisateur WHERE pseudo = 'lorette'") is None
        assert client.get("/moi", headers={"X-Cle-Api": nouvelle}).status_code == 200
        assert client.get("/moi", headers=lorette).status_code == 401

        # La règle de longueur tient encore, alors que la colonne repart vide.
        with pytest.raises(psycopg.errors.CheckViolation):
            sql("UPDATE utilisateur SET cle_api = 'courte' WHERE pseudo = 'lorette'")
    finally:
        sql("UPDATE utilisateur SET cle_api = %s WHERE pseudo = 'lorette'", CLE_LORETTE)


def test_chaque_connexion_ouvre_sa_propre_session(client, thomas):
    telephone = _connecter(client, appareil="iPhone de Thomas")
    tablette = _connecter(client, appareil="iPad")

    assert telephone != tablette != thomas
    for cle in (telephone, tablette):
        assert client.get("/moi", headers=cle).json()["pseudo"] == "thomas"
        # La base n'en garde que l'empreinte.
        assert un("SELECT count(*) FROM session_appareil WHERE empreinte = %s",
                  _empreinte(cle["X-Cle-Api"])) == 1
    assert un("SELECT count(*) FROM session_appareil WHERE empreinte = %s",
              telephone["X-Cle-Api"]) == 0

    liste = client.get("/moi/sessions", headers=telephone).json()
    assert sorted(s["nom"] for s in liste) == ["iPad", "iPhone de Thomas"]
    assert [s["nom"] for s in liste if s["courante"]] == ["iPhone de Thomas"]


def test_se_deconnecter_ne_revoque_que_cet_appareil(client, thomas):
    telephone = _connecter(client)
    tablette = _connecter(client)

    fermee = client.delete("/moi/session", headers=telephone)

    assert fermee.status_code == 200
    assert client.get("/moi", headers=telephone).status_code == 401
    assert client.get("/moi", headers=tablette).status_code == 200
    assert client.get("/moi", headers=thomas).status_code == 200
    assert len(client.get("/moi/sessions", headers=tablette).json()) == 1


def test_la_cle_du_compte_ne_se_revoque_pas_comme_une_session(client, thomas):
    refus = client.delete("/moi/session", headers=thomas)

    assert refus.status_code == 409 and refus.json()["code"] == "cle_du_compte"
    assert client.get("/moi", headers=thomas).status_code == 200


def test_fermer_la_session_d_un_autre_appareil(client, thomas, lorette):
    oublie = _connecter(client, appareil="Vieil iPhone")
    actuel = _connecter(client)
    id_oublie = next(s["id_session"] for s in client.get("/moi/sessions", headers=actuel).json()
                     if not s["courante"])

    # Seulement les siennes : Lorette ne ferme pas une session de Thomas.
    assert client.delete(f"/moi/sessions/{id_oublie}", headers=lorette).status_code == 404
    assert client.get("/moi", headers=oublie).status_code == 200

    assert client.delete(f"/moi/sessions/{id_oublie}", headers=actuel).status_code == 200
    assert client.get("/moi", headers=oublie).status_code == 401
    assert client.delete(f"/moi/sessions/{id_oublie}", headers=actuel).status_code == 404


def test_un_compte_en_pause_n_ouvre_plus_rien(client):
    cle = _connecter(client, "lorette")

    sql("UPDATE utilisateur SET actif = FALSE WHERE pseudo = 'lorette'")

    assert client.get("/moi", headers=cle).status_code == 401


def test_le_bot_d_administration_s_appaire_avec_une_session(client):
    session = _connecter(client)
    assert appairage.appairer(session["X-Cle-Api"], 4242)["pseudo"] == "thomas"
    assert appairage.appairer(CLE_THOMAS, 4242)["pseudo"] == "thomas"
    # Ni la clé d'un compte qui n'est pas administrateur, ni une clé inconnue.
    assert appairage.appairer(_connecter(client, "lorette")["X-Cle-Api"], 4343) is None
    assert appairage.appairer("X" * 48, 4343) is None
