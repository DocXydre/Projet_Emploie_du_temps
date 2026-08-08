from datetime import UTC, datetime

import pytest
from fastapi.testclient import TestClient

from app import registre
from app.contrat import Collecteur, EtatSante, Occupation, SanteCollecteur, TypeOccupation
from app.main import app

client = TestClient(app)


class CollecteurFactice(Collecteur):
    code_source = "SOURCE_TEST"

    def __init__(self, etat: EtatSante = EtatSante.OK) -> None:
        self._etat = etat
        self.publie: list[Occupation] = []

    async def recuperer(self):
        return [{"uid": "abc", "libelle": "Cours de test"}]

    async def normaliser(self, brut):
        return [
            Occupation(
                cle_externe=e["uid"],
                type=TypeOccupation.COURS,
                debut=datetime(2026, 9, 15, 8, 0, tzinfo=UTC),
                fin=datetime(2026, 9, 15, 10, 0, tzinfo=UTC),
                libelle=e["libelle"],
            )
            for e in brut
        ]

    async def publier(self, occupations):
        self.publie = occupations

    async def sante(self) -> SanteCollecteur:
        return SanteCollecteur(code_source=self.code_source, etat=self._etat)


@pytest.fixture(autouse=True)
def registre_vierge():
    registre._COLLECTEURS.clear()
    yield
    registre._COLLECTEURS.clear()


def test_sante_repond_ok_sans_collecteur_enregistre():
    reponse = client.get("/sante")
    assert reponse.status_code == 200
    corps = reponse.json()
    assert corps["service"] == "planif-collecteurs"
    assert corps["etat"] == "OK"
    assert corps["collecteurs"] == []


def test_sante_repond_503_si_un_collecteur_est_mort():
    registre.enregistrer(CollecteurFactice(EtatSante.MORT))
    reponse = client.get("/sante")
    assert reponse.status_code == 503
    assert reponse.json()["etat"] == "MORT"


def test_sante_reste_disponible_en_mode_degrade():
    registre.enregistrer(CollecteurFactice(EtatSante.DEGRADE))
    reponse = client.get("/sante")
    assert reponse.status_code == 200
    assert reponse.json()["etat"] == "DEGRADE"


def test_forcage_de_collecte_execute_le_cycle_complet():
    collecteur = CollecteurFactice()
    registre.enregistrer(collecteur)

    reponse = client.post("/collecteurs/SOURCE_TEST/collecter")

    assert reponse.status_code == 200
    corps = reponse.json()
    assert corps["code_source"] == "SOURCE_TEST"
    assert corps["occupations"][0]["cle_externe"] == "abc"
    assert len(collecteur.publie) == 1


def test_forcage_sur_collecteur_inconnu_renvoie_404():
    assert client.post("/collecteurs/INEXISTANT/collecter").status_code == 404
