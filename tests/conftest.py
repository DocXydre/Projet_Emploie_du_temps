"""Base de test : on rejoue les migrations puis on crée deux comptes.

Les tests tournent contre un vrai PostgreSQL. Sans lui, on ne vérifierait que
le code Python, alors que c'est la base qui porte les règles.
"""

import os
from pathlib import Path

# L'ordonnanceur ne doit pas tourner pendant les tests : on déclenche les tâches
# à la main plutôt que de dépendre de l'heure qu'il est. Réglé avant tout import
# d'api.config, dont la configuration est mise en cache.
os.environ.setdefault("ORDONNANCEUR_ACTIF", "false")

import psycopg
import pytest
from fastapi.testclient import TestClient

# Racine du dépôt, d'où sont lus les fichiers SQL. Surchargeable pour pouvoir
# exécuter les tests depuis un autre répertoire.
RACINE = Path(os.environ.get("PLANIF_RACINE") or Path(__file__).resolve().parent.parent)
CLE_THOMAS = "T" * 48
CLE_LORETTE = "L" * 48

# Le flux iCalendar ne s'authentifie pas avec la clé d'API : cette URL vit en
# clair dans le téléphone, elle ne doit donc ouvrir que la lecture du planning.
JETON_THOMAS = "t" * 32
JETON_LORETTE = "l" * 32


def _url() -> str:
    return (
        f"postgresql://{os.environ.get('POSTGRES_USER', 'planif')}:"
        f"{os.environ.get('POSTGRES_PASSWORD', 'planif')}@"
        f"{os.environ.get('DB_HOTE', 'localhost')}:"
        f"{os.environ.get('DB_PORT', '5432')}/"
        f"{os.environ.get('POSTGRES_DB', 'planif')}"
    )


@pytest.fixture(scope="session", autouse=True)
def base():
    """Schéma reconstruit une fois pour toute la session de test."""
    with psycopg.connect(_url(), autocommit=True) as conn:
        conn.execute("DROP SCHEMA public CASCADE; CREATE SCHEMA public;")
        for fichier in sorted(RACINE.glob("sql/0[0-9][0-9]_*.sql")):
            conn.execute(fichier.read_text())

        conn.execute(
            """
            INSERT INTO utilisateur (pseudo, nom, role, cle_api, jeton_calendrier) VALUES
                ('thomas', 'Thomas', 'admin', %s, %s),
                ('lorette', 'Lorette', 'standard', %s, %s)
            """,
            (CLE_THOMAS, JETON_THOMAS, CLE_LORETTE, JETON_LORETTE),
        )
        # Rejoué après création des comptes : c'est là que les assignations
        # par défaut prennent effet.
        conn.execute((RACINE / "sql" / "006_assignations.sql").read_text())
        conn.execute("SELECT assigner_calendriers_perso()")
    yield


@pytest.fixture
def client(base):
    from api.main import app

    with TestClient(app) as c:
        yield c


@pytest.fixture
def thomas() -> dict[str, str]:
    return {"X-Cle-Api": CLE_THOMAS}


@pytest.fixture
def lorette() -> dict[str, str]:
    return {"X-Cle-Api": CLE_LORETTE}


@pytest.fixture(autouse=True)
def table_rase(base):
    """Chaque test repart d'un planning vide, mais garde les données de référence."""
    with psycopg.connect(_url(), autocommit=True) as conn:
        conn.execute("DELETE FROM mouvement_stock")
        conn.execute("DELETE FROM notification")
        conn.execute("DELETE FROM occurrence")
        conn.execute("DELETE FROM occupation")
        conn.execute("UPDATE article_travail SET quantite_propre = quantite_totale, "
                     "disponible_le = NULL")
        conn.execute("DELETE FROM conflit")
        conn.execute("DELETE FROM proposition")
        conn.execute("DELETE FROM courriel")
        conn.execute("DELETE FROM trajet")
        conn.execute("DELETE FROM absence")
        # Les calendriers personnels naissent inactifs, faute d'URL : les
        # rallumer ici les ferait passer pour des sources en panne dans tous
        # les tests qui vérifient le bilan du matin.
        conn.execute("UPDATE source SET derniere_collecte = NULL, etat = 'ok', "
                     "url = NULL, active = (code NOT LIKE 'PERSO\\_%')")
        conn.execute("UPDATE utilisateur SET id_telegram = NULL")
        # Un test qui renouvelle son jeton d'abonnement ne doit pas invalider
        # l'URL de calendrier des suivants.
        conn.execute(
            "UPDATE utilisateur SET jeton_calendrier = CASE pseudo "
            "WHEN 'thomas' THEN %s ELSE %s END",
            (JETON_THOMAS, JETON_LORETTE),
        )
    yield
