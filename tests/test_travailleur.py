"""L'API et le travailleur, deux processus de la même image

L'ordonnanceur, le bot et les appels planifiés de HAL tournent dans le
travailleur (api/travailleur.py). L'API ne les démarre plus, relaie la sonde du
travailleur dans /sante, et les erreurs des deux se lisent au même endroit.
"""

import logging

import httpx
import pytest
from fastapi.testclient import TestClient

from api import administration, bot, ordonnanceur
from api.base import transaction_annulee
from api.config import configuration


@pytest.fixture(autouse=True)
def sans_erreurs():
    administration.oublier_les_erreurs()
    yield
    administration.installer("api")
    administration.oublier_les_erreurs()


class _Reponse:
    def __init__(self, corps: dict):
        self.corps = corps

    def json(self) -> dict:
        return self.corps


def test_l_api_ne_demarre_ni_l_ordonnanceur_ni_le_bot(monkeypatch):
    from api.main import app

    monkeypatch.setattr(configuration(), "ordonnanceur_actif", True)
    with TestClient(app):
        assert ordonnanceur.taches_programmees() == []
        assert bot.identite() is None


def test_le_travailleur_a_sa_sonde_et_son_serveur_mcp():
    from api.travailleur import app

    with TestClient(app) as travailleur:
        sante = travailleur.get("/sante").json()
        assert sante["service"] == "planif-travailleur"
        # Coupé pendant les essais : il tourne sans rien déclencher.
        assert sante["etat"] == "ok" and sante["ordonnanceur"] == []

        # MCP-14 : un jeton de course ne vaut que depuis le conteneur lui-même.
        course = travailleur.post("/mcp", headers={"X-Jeton-Course": "inconnu"}, json={})
        assert course.status_code == 401
        assert course.json()["code"] == "jeton_course_invalide"
        assert travailleur.post("/mcp", json={}).json()["code"] == "cle_mcp_invalide"
        # Rien d'autre : l'appli parle à l'API.
        assert travailleur.get("/moi").status_code == 404


def test_la_sonde_de_l_api_relaie_celle_du_travailleur(client, monkeypatch):
    monkeypatch.setattr(configuration(), "travailleur_adresse", "http://travailleur:8000")
    appels = []

    def sonde(url, timeout):
        appels.append(url)
        return _Reponse({"etat": "ok", "bot": "@hal_bot",
                         "ordonnanceur": [{"id": "placement", "nom": "Placement du matin"}]})

    monkeypatch.setattr(httpx, "get", sonde)

    sante = client.get("/sante").json()

    assert appels == ["http://travailleur:8000/sante"]
    assert sante["etat"] == "ok" and sante["travailleur"] == "ok"
    assert sante["bot"] == "@hal_bot"
    assert [t["id"] for t in sante["ordonnanceur"]] == ["placement"]


def test_sans_travailleur_l_api_se_dit_degradee(client, monkeypatch):
    # Plus rien ne part tout seul : le déploiement doit le voir.
    monkeypatch.setattr(configuration(), "travailleur_adresse", "http://travailleur:8000")

    def injoignable(url, timeout):
        raise httpx.ConnectError("Connection refused")

    monkeypatch.setattr(httpx, "get", injoignable)

    sante = client.get("/sante").json()

    assert sante["etat"] == "degrade" and sante["travailleur"] == "injoignable"
    assert sante["base"] == "ok"


def test_les_erreurs_du_travailleur_se_lisent_avec_celles_de_l_api():
    administration.installer("api")
    logging.getLogger("api.essai").error("Côté API")
    administration.installer("travailleur")
    logging.getLogger("api.ordonnanceur").error("Côté travailleur")

    erreurs = administration.dernieres_erreurs()

    assert [(e["processus"], e["message"]) for e in erreurs] == [
        ("travailleur", "Côté travailleur"), ("api", "Côté API")]
    assert administration.erreurs_recentes() == 2
    texte = administration.erreurs_en_clair()
    assert "api.ordonnanceur (travailleur) : Côté travailleur" in texte
    assert "api.essai : Côté API" in texte


def test_une_erreur_dans_une_transaction_annulee_reste_notee():
    administration.installer("api")

    with transaction_annulee():
        logging.getLogger("api.essai").error("Pendant un essai")

    assert [e["message"] for e in administration.dernieres_erreurs()] == ["Pendant un essai"]


def test_sans_base_une_erreur_ne_casse_rien(monkeypatch):
    administration.installer("api")
    monkeypatch.setattr(administration._memoire, "_connexion", None)
    monkeypatch.setattr(administration._memoire, "_en_pause_jusqu_a", None)

    def base_tombee(*args, **kwargs):
        raise OSError("base injoignable")

    monkeypatch.setattr(administration.psycopg, "connect", base_tombee)

    logging.getLogger("api.essai").error("Personne ne la notera")

    # Le journal continue, et l'écriture se tait un moment au lieu de réessayer
    # à chaque erreur.
    assert administration._memoire._en_pause_jusqu_a is not None
    monkeypatch.undo()
    administration._memoire._en_pause_jusqu_a = None
    assert administration.dernieres_erreurs() == []
