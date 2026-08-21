"""L'abonnement au calendrier : un jeton à part, et une URL qui ne bouge pas.

Deux choses se vérifient ici, et elles n'ont pas le même poids.

La première est une question de sécurité : l'URL d'abonnement vit en clair dans
le téléphone, dans ses sauvegardes, et repart à chaque rafraîchissement. Elle ne
doit ouvrir que la lecture du planning — surtout pas le reste de l'API.

La seconde est une question d'usage : l'adresse contient le nom de la machine,
et si ce nom est une adresse IP, l'abonnement cesse de fonctionner dès qu'on
change de réseau. D'où `HOTE_PUBLIC`, qui l'emporte sur ce que dit la requête.
"""

import psycopg
import pytest

from api import conversation as conv
from api.config import configuration
from tests.conftest import CLE_THOMAS, JETON_LORETTE, JETON_THOMAS, _url

TELEGRAM_THOMAS = 111222333


@pytest.fixture
def hote_fixe():
    """Fixe HOTE_PUBLIC le temps d'un test, en contournant le cache de config."""
    conf = configuration()
    ancien = conf.hote_public
    conf.hote_public = "mon-mac.local:8000"
    yield "mon-mac.local:8000"
    conf.hote_public = ancien


# ---------------------------------------------------------------------------
# Cloisonnement
# ---------------------------------------------------------------------------

def test_le_jeton_de_calendrier_ouvre_le_flux(client):
    assert client.get("/planning.ics", params={"cle": JETON_THOMAS}).status_code == 200


def test_la_cle_d_api_n_ouvre_plus_le_flux(client):
    # Le point de toute la manœuvre. Avant, cette URL marchait — et donnait
    # donc au téléphone une clé qui vaut pour l'API entière.
    reponse = client.get("/planning.ics", params={"cle": CLE_THOMAS})
    assert reponse.status_code == 401
    assert reponse.json()["code"] == "jeton_invalide"


def test_le_jeton_de_calendrier_n_ouvre_rien_d_autre(client):
    # Symétrie du test précédent : le jeton ne doit pas non plus servir de clé.
    assert client.get("/moi", headers={"X-Cle-Api": JETON_THOMAS}).status_code == 401


def test_chacun_voit_son_propre_planning(client, thomas):
    client.post("/planning/placer", headers=thomas)

    mien = client.get("/planning.ics", params={"cle": JETON_THOMAS}).content
    sien = client.get("/planning.ics", params={"cle": JETON_LORETTE}).content
    assert mien != sien


def test_un_flux_sans_jeton_est_refuse(client):
    reponse = client.get("/planning.ics")
    assert reponse.status_code == 401
    assert reponse.json()["code"] == "jeton_absent"


def test_un_compte_desactive_perd_son_abonnement(client):
    with psycopg.connect(_url(), autocommit=True) as conn:
        conn.execute("UPDATE utilisateur SET actif = FALSE WHERE pseudo = 'lorette'")
    try:
        assert client.get("/planning.ics",
                          params={"cle": JETON_LORETTE}).status_code == 401
    finally:
        with psycopg.connect(_url(), autocommit=True) as conn:
            conn.execute("UPDATE utilisateur SET actif = TRUE WHERE pseudo = 'lorette'")


# ---------------------------------------------------------------------------
# Renouvellement
# ---------------------------------------------------------------------------

def test_renouveler_coupe_l_abonnement_en_place(client, thomas):
    nouveau = client.post("/moi/calendrier/renouveler", headers=thomas).json()

    assert JETON_THOMAS not in nouveau["url"]
    assert client.get("/planning.ics", params={"cle": JETON_THOMAS}).status_code == 401

    jeton = nouveau["url"].split("cle=")[1]
    assert client.get("/planning.ics", params={"cle": jeton}).status_code == 200


def test_renouveler_ne_touche_pas_a_la_cle_d_api(client, thomas):
    client.post("/moi/calendrier/renouveler", headers=thomas)
    # Se réabonner ne doit pas obliger à réappairer le bot ni à refaire le .env.
    assert client.get("/moi", headers=thomas).status_code == 200


def test_renouveler_n_affecte_que_soi(client, thomas):
    client.post("/moi/calendrier/renouveler", headers=thomas)
    assert client.get("/planning.ics", params={"cle": JETON_LORETTE}).status_code == 200


# ---------------------------------------------------------------------------
# Construction de l'URL
# ---------------------------------------------------------------------------

def test_l_url_est_construite_sur_l_hote_public(client, thomas, hote_fixe):
    lien = client.get("/moi/calendrier", headers=thomas).json()

    assert lien["url"] == f"http://{hote_fixe}/planning.ics?cle={JETON_THOMAS}"
    assert lien["deduit_de_la_requete"] is False


def test_l_hote_public_l_emporte_sur_la_requete(client, thomas, hote_fixe):
    # Interrogée depuis le Mac, l'API voit « testserver » ou « localhost ».
    # Répondre cela au téléphone donnerait une adresse qui pointe vers lui-même.
    lien = client.get("/moi/calendrier", headers=thomas).json()
    assert "localhost" not in lien["url"]
    assert "testserver" not in lien["url"]


def test_sans_hote_public_l_url_vient_de_la_requete(client, thomas):
    lien = client.get("/moi/calendrier", headers=thomas).json()
    assert lien["deduit_de_la_requete"] is True
    assert lien["hote"] == "testserver"


def test_le_lien_webcal_double_le_lien_http(client, thomas, hote_fixe):
    lien = client.get("/moi/calendrier", headers=thomas).json()
    # Touché sur un téléphone, webcal:// ouvre directement la boîte de dialogue
    # d'abonnement : personne ne recopie trente-deux caractères sans se tromper.
    assert lien["webcal"] == lien["url"].replace("http://", "webcal://")


def test_sans_hote_connu_le_bot_ne_fabrique_pas_d_url(base):
    # Le bot n'a pas de requête d'où déduire un hôte : il vaut mieux qu'il dise
    # ce qui manque plutôt qu'il envoie une adresse fausse.
    compte = conv.appairer(CLE_THOMAS, TELEGRAM_THOMAS)
    assert conv.url_calendrier(compte["id_utilisateur"]) is None


def test_le_bot_fabrique_l_url_des_que_l_hote_est_connu(base, hote_fixe):
    compte = conv.appairer(CLE_THOMAS, TELEGRAM_THOMAS)
    lien = conv.url_calendrier(compte["id_utilisateur"])

    assert lien is not None
    assert lien["url"].startswith("http://mon-mac.local:8000/planning.ics?cle=")


def test_un_hote_donne_avec_son_protocole_ne_le_double_pas(base):
    compte = conv.appairer(CLE_THOMAS, TELEGRAM_THOMAS)
    lien = conv.url_calendrier(compte["id_utilisateur"], "http://mon-mac.local:8000")

    assert lien is not None
    assert lien["url"].count("http://") == 1
