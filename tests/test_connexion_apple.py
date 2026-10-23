"""Se connecter avec Apple                                         (CNX-7 à CNX-9)

Apple n'est jamais appelé : une clé RSA tirée ici signe les jetons, et ses
paramètres publics remplacent ceux qu'Apple publie.
"""

import base64
import json
import time

import pytest
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding, rsa

from api import identifiant_apple, mot_de_passe
from tests.test_ensemble import _id, un
from tests.test_foyer import MOT_DE_PASSE, _inviter, _liberer_une_place

CLE = rsa.generate_private_key(public_exponent=65537, key_size=2048)
AUTRE_CLE = rsa.generate_private_key(public_exponent=65537, key_size=2048)


def _b64(donnees: bytes) -> str:
    return base64.urlsafe_b64encode(donnees).rstrip(b"=").decode()


def _entier(n: int) -> str:
    return _b64(n.to_bytes((n.bit_length() + 7) // 8, "big"))


def _jeton(sub: str = "000123.apple.thomas", cle=CLE, **corps) -> str:
    entete = _b64(json.dumps({"alg": "RS256", "kid": "cle-test"}).encode())
    contenu = {"iss": "https://appleid.apple.com", "aud": "fr.docxydre.hal", "sub": sub,
               "iat": int(time.time()), "exp": int(time.time()) + 600, **corps}
    charge = _b64(json.dumps(contenu).encode())
    signature = cle.sign(f"{entete}.{charge}".encode(), padding.PKCS1v15(), hashes.SHA256())
    return f"{entete}.{charge}.{_b64(signature)}"


@pytest.fixture(autouse=True)
def cles_d_apple(monkeypatch):
    publique = CLE.public_key().public_numbers()
    monkeypatch.setattr(identifiant_apple, "_telecharger_cles", lambda: [
        {"kty": "RSA", "kid": "cle-test", "alg": "RS256",
         "n": _entier(publique.n), "e": _entier(publique.e)}])
    identifiant_apple.oublier_les_cles()
    yield
    identifiant_apple.oublier_les_cles()


def test_un_identifiant_apple_inconnu_demande_le_mot_de_passe_une_fois(client, thomas):
    inconnu = client.post("/connexion/apple", json={"jeton": _jeton()})
    assert inconnu.status_code == 404 and inconnu.json()["code"] == "apple_inconnu"

    mot_de_passe.choisir(_id("thomas"), MOT_DE_PASSE)
    relie = client.post("/connexion", json={"pseudo": "thomas", "mot_de_passe": MOT_DE_PASSE,
                                            "jeton_apple": _jeton()})
    assert relie.status_code == 200 and relie.json()["pseudo"] == "thomas"

    # Ensuite, Apple suffit. Chaque connexion a sa clé (CNX-11).
    apple = client.post("/connexion/apple", json={"jeton": _jeton()})
    assert apple.status_code == 200 and apple.json()["pseudo"] == "thomas"
    assert apple.json()["cle_api"] not in (relie.json()["cle_api"], thomas["X-Cle-Api"])
    assert client.get("/moi", headers={"X-Cle-Api": apple.json()["cle_api"]}
                      ).json()["pseudo"] == "thomas"
    assert client.get("/moi/apple", headers=thomas).json() == {"relie": True}


def test_un_jeton_qui_ne_vient_pas_d_apple_est_refuse(client, thomas):
    client.put("/moi/apple", headers=thomas, json={"jeton": _jeton()})
    refuses = [
        _jeton(cle=AUTRE_CLE),                       # pas signé par Apple
        _jeton(aud="fr.quelquun.dautre"),            # pour une autre appli
        _jeton(iss="https://ailleurs.example"),
        _jeton(exp=int(time.time()) - 3600),         # expiré
        "pas.un.jeton",
    ]
    for jeton in refuses:
        reponse = client.post("/connexion/apple", json={"jeton": jeton})
        assert reponse.status_code == 401, jeton
        assert reponse.json()["code"] == "apple_refuse"


def test_un_jeton_refuse_ne_compte_pas_comme_un_echec_du_mot_de_passe(client, thomas):
    mot_de_passe.choisir(_id("thomas"), MOT_DE_PASSE)
    for _ in range(6):
        client.post("/connexion", json={"pseudo": "thomas", "mot_de_passe": MOT_DE_PASSE,
                                        "jeton_apple": _jeton(cle=AUTRE_CLE)})
    assert un("SELECT echecs_connexion FROM utilisateur WHERE pseudo = 'thomas'") == 0
    assert un("SELECT identifiant_apple FROM utilisateur WHERE pseudo = 'thomas'") is None


def test_relier_et_delier_depuis_les_reglages(client, thomas, lorette):
    assert client.put("/moi/apple", headers=thomas, json={"jeton": _jeton()}).status_code == 200
    # Le même identifiant relié à un autre compte quitte le premier.
    assert client.put("/moi/apple", headers=lorette, json={"jeton": _jeton()}).status_code == 200
    assert client.get("/moi/apple", headers=thomas).json() == {"relie": False}
    assert client.post("/connexion/apple", json={"jeton": _jeton()}
                       ).json()["pseudo"] == "lorette"

    assert client.delete("/moi/apple", headers=lorette).json() == {"relie": False}
    assert client.post("/connexion/apple", json={"jeton": _jeton()}).status_code == 404


def test_rejoindre_le_foyer_avec_apple_sans_mot_de_passe(client, thomas, lorette):
    _liberer_une_place(client, thomas, lorette)
    code = _inviter(client, thomas)
    rejoint = client.post(f"/invitations/{code}/accepter",
                          json={"pseudo": "camille", "jeton_apple": _jeton("000999.camille")})
    assert rejoint.status_code == 201, rejoint.text
    assert un("SELECT mot_de_passe FROM utilisateur WHERE pseudo = 'camille'") is None
    apple = client.post("/connexion/apple", json={"jeton": _jeton("000999.camille")})
    assert apple.json()["pseudo"] == "camille"
    assert client.get("/moi", headers={"X-Cle-Api": apple.json()["cle_api"]}
                      ).json()["pseudo"] == "camille"


def test_rejoindre_sans_apple_demande_toujours_un_mot_de_passe(client, thomas, lorette):
    _liberer_une_place(client, thomas, lorette)
    code = _inviter(client, thomas)
    refus = client.post(f"/invitations/{code}/accepter", json={"pseudo": "camille"})
    assert refus.status_code == 422


def test_un_identifiant_apple_deja_relie_ne_cree_pas_un_second_compte(client, thomas, lorette):
    client.put("/moi/apple", headers=thomas, json={"jeton": _jeton()})
    _liberer_une_place(client, thomas, lorette)
    code = _inviter(client, thomas)
    refus = client.post(f"/invitations/{code}/accepter",
                        json={"pseudo": "camille", "jeton_apple": _jeton()})
    assert refus.status_code == 409 and "thomas" in refus.json()["message"]
