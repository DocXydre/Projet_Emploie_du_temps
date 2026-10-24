"""La clé du serveur reste en secours quand on branche son abonnement (FOU-1,
migration 075)."""

# ruff: noqa: F811 (les fixtures de test_coach sont importées puis demandées)

import pytest
from cryptography.fernet import Fernet

from api.coach import fournisseurs
from api.config import configuration
from tests.conftest import RACINE
from tests.test_coach import u  # noqa: F401
from tests.test_ensemble import sql, un


@pytest.fixture(autouse=True)
def sans_fournisseur():
    """La base de test ne vide pas cette table d'un test à l'autre."""
    sql("DELETE FROM fournisseur_modele")


@pytest.fixture
def serveur(monkeypatch):
    """Un serveur qui a une clé d'API et de quoi chiffrer les jetons."""
    conf = configuration().model_copy(update={
        "anthropic_api_key": "sk-ant-serveur",
        "hal_cle_chiffrement": Fernet.generate_key().decode()})
    monkeypatch.setattr(fournisseurs, "configuration", lambda: conf)
    return conf


def _types(u: int) -> list[tuple[str, bool]]:
    return [(ligne["type"], ligne["secret"] is None) for ligne in sql(
        "SELECT type, secret FROM fournisseur_modele WHERE id_utilisateur = %s ORDER BY rang", u)]


def test_brancher_l_abonnement_garde_la_cle_du_serveur_derriere(serveur, u):
    assert [f.type for f in fournisseurs.chaine(u)] == ["serveur"]
    fournisseurs.brancher(u, "claude_code", "sk-ant-oat01-jeton", None)
    assert _types(u) == [("claude_code", False), ("api", True)]
    chaine = fournisseurs.chaine(u)
    assert [f.type for f in chaine] == ["claude_code", "api"]
    # Sans secret : l'appel prend la clé du serveur, avec le plafond par défaut.
    assert chaine[1].secret is None and chaine[1].plafond == serveur.plafond_api_defaut
    assert fournisseurs.lister_pour(u)["cle_du_serveur"] is False


def test_un_deuxieme_branchement_ne_rajoute_rien(serveur, u):
    fournisseurs.brancher(u, "claude_code", "sk-ant-oat01-jeton", None)
    fournisseurs.changer_etat(u, "api", coupe=True)
    fournisseurs.brancher(u, "claude_code", "sk-ant-oat01-autre", None)
    assert _types(u) == [("claude_code", False), ("api", True)]
    # Coupée à la main, elle le reste.
    assert un("SELECT etat FROM fournisseur_modele WHERE type = 'api'") == "coupe"


def test_une_cle_a_soi_remplace_celle_du_serveur(serveur, u):
    fournisseurs.brancher(u, "claude_code", "sk-ant-oat01-jeton", None)
    fournisseurs.brancher(u, "api", "sk-ant-api03-perso", 20)
    assert _types(u) == [("claude_code", False), ("api", False)]


def test_sans_cle_sur_le_serveur_rien_n_est_ajoute(monkeypatch, u):
    conf = configuration().model_copy(update={
        "anthropic_api_key": "", "hal_cle_chiffrement": Fernet.generate_key().decode()})
    monkeypatch.setattr(fournisseurs, "configuration", lambda: conf)
    fournisseurs.brancher(u, "claude_code", "sk-ant-oat01-jeton", None)
    assert _types(u) == [("claude_code", False)]


def test_la_migration_rend_le_secours_aux_comptes_deja_branches(serveur, u):
    sql("INSERT INTO fournisseur_modele (id_utilisateur, type, rang, secret, secret_fin) "
        "VALUES (%s, 'claude_code', 1, '\\x00', 'abcd')", u)
    migration = (RACINE / "sql" / "075_cle_du_serveur_en_secours.sql").read_text(encoding="utf-8")
    sql(migration)
    sql(migration)
    assert _types(u) == [("claude_code", False), ("api", True)]
