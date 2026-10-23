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
from psycopg.types.json import Json

# Racine du dépôt, d'où sont lus les fichiers SQL. Surchargeable pour pouvoir
# exécuter les tests depuis un autre répertoire.
RACINE = Path(os.environ.get("PLANIF_RACINE") or Path(__file__).resolve().parent.parent)
CLE_THOMAS = "T" * 48
CLE_LORETTE = "L" * 48

# Le flux iCalendar ne s'authentifie pas avec la clé d'API : cette URL vit en
# clair dans le téléphone, elle ne doit donc ouvrir que la lecture du planning.
JETON_THOMAS = "t" * 32
JETON_LORETTE = "l" * 32

# Configuration de chaque source telle que les données de référence la posent,
# relevée une fois pour pouvoir la restaurer entre deux tests.
_CONFIGURATIONS_INITIALES: dict[str, dict] = {}


def _url() -> str:
    return (
        f"postgresql://{os.environ.get('POSTGRES_USER', 'planif')}:"
        f"{os.environ.get('POSTGRES_PASSWORD', 'planif')}@"
        f"{os.environ.get('DB_HOTE', 'localhost')}:"
        f"{os.environ.get('DB_PORT', '5432')}/"
        f"{os.environ.get('POSTGRES_DB', 'planif')}"
    )


def flux_definitions() -> str:
    """Le SQL de `sql/definitions/`, dans l'ordre où `appliquer.sh` le charge.

    Les fonctions sans vérification de leur corps, puis les vues retirées dans
    l'ordre inverse de leur numéro et recréées, puis les déclencheurs.
    """
    dossier = RACINE / "sql" / "definitions"
    vues = sorted((dossier / "vues").glob("[0-9][0-9]_*.sql"))
    morceaux = ["SET LOCAL check_function_bodies = off;"]
    morceaux += [f.read_text() for f in sorted((dossier / "fonctions").glob("*.sql"))]
    morceaux += [f"DROP VIEW IF EXISTS {v.stem.split('_', 1)[1]};" for v in reversed(vues)]
    morceaux += [v.read_text() for v in vues]
    morceaux.append((dossier / "declencheurs.sql").read_text())
    return "\n".join(morceaux)


def charger_definitions(conn) -> None:
    """Remet fonctions, vues et déclencheurs tels que le dépôt les décrit."""
    with conn.transaction():
        conn.execute(flux_definitions())


@pytest.fixture(scope="session", autouse=True)
def base():
    """Schéma reconstruit une fois pour toute la session de test."""
    with psycopg.connect(_url(), autocommit=True) as conn:
        # L'archive des fonctionnalités retirées vit hors de public : elle
        # survivrait sinon d'une session à l'autre, et la migration qui la
        # remplit la trouverait déjà pleine.
        conn.execute("DROP SCHEMA IF EXISTS archive CASCADE;"
                     "DROP SCHEMA public CASCADE; CREATE SCHEMA public;")
        # Le même ordre que `sql/appliquer.sh` : les migrations, les définitions,
        # puis les rattrapages.
        for fichier in sorted(RACINE.glob("sql/0[0-9][0-9]_*.sql")):
            conn.execute(fichier.read_text())
        charger_definitions(conn)
        for fichier in sorted(RACINE.glob("sql/apres/[0-9][0-9][0-9]_*.sql")):
            conn.execute(fichier.read_text())

        conn.execute(
            """
            INSERT INTO utilisateur (pseudo, nom, role, cle_api, jeton_calendrier) VALUES
                ('thomas', 'Thomas', 'admin', %s, %s),
                ('lorette', 'Lorette', 'standard', %s, %s)
            """,
            (CLE_THOMAS, JETON_THOMAS, CLE_LORETTE, JETON_LORETTE),
        )
        # Rappelée après création des comptes, comme l'API le fait à son
        # démarrage : c'est là que les assignations par défaut prennent effet.
        conn.execute("SELECT amorcer_foyer()")
        conn.execute("SELECT appliquer_assignations()")
        conn.execute("SELECT assigner_calendriers_perso()")

        _CONFIGURATIONS_INITIALES.clear()
        for code, configuration in conn.execute(
                "SELECT code, configuration FROM source").fetchall():
            _CONFIGURATIONS_INITIALES[code] = configuration
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
        conn.execute("DELETE FROM notification")
        # ACT-2 : un geste ou une demande d'un test ne passe pas au suivant.
        conn.execute("DELETE FROM demande")
        # Le coach. Les échanges d'abord : une notification pouvait en citer un.
        # Supprimer les occurrences emporte ensuite les séances, leurs
        # exercices, leurs séries, leurs bilans et leurs ajustements.
        for table in ("trace_coach", "echange", "appel_coach", "note_coach", "memoire_coach",
                      "demarrage_coach", "activite_sante", "sante_jour", "echantillon_sante",
                      "sommeil_phase", "mesure",
                      "fenetre_mesure"):
            conn.execute(f"DELETE FROM {table}")
        conn.execute("DELETE FROM occurrence")
        for table in ("plan", "objectif", "limitation", "discipline_lieu", "profil",
                      "depistage", "pause"):
            conn.execute(f"DELETE FROM {table}")
        # EXO-11 : un exercice ajouté par un test n'est pas au catalogue du suivant.
        # Un exercice ne se supprime jamais : le temps du ménage seulement.
        conn.execute("ALTER TABLE exercice DISABLE TRIGGER exercice_conserve")
        conn.execute("DELETE FROM exercice WHERE id_utilisateur IS NOT NULL")
        conn.execute("ALTER TABLE exercice ENABLE TRIGGER exercice_conserve")
        # Le coach s'active par compte : un test qui l'allume ne doit pas
        # changer le sport des suivants.
        conn.execute("UPDATE utilisateur SET coach_actif = FALSE, repos_dur_heures = 48, "
                     "seances_max_semaine = NULL, besoin_sommeil_minutes = 480")
        conn.execute("DELETE FROM occupation")
        conn.execute("DELETE FROM conflit")
        conn.execute("DELETE FROM proposition")
        # Les fermetures créées par un test ne doivent pas survivre au suivant :
        # une piscine fermée par erreur ferait échouer des tests sans rapport,
        # et le motif ne dirait pas d'où elle vient. Seule la pause estivale,
        # qui fait partie des données de référence, est conservée.
        conn.execute("DELETE FROM fermeture "
                     " WHERE motif IS NULL OR motif NOT LIKE 'Pause estivale%'")
        # Les calendriers composés appartiennent à leur test : un jeton laissé
        # derrière ferait passer une liste vide pour une liste pleine.
        conn.execute("DELETE FROM calendrier")
        conn.execute("DELETE FROM courriel")
        conn.execute("DELETE FROM trajet")
        conn.execute("DELETE FROM absence")
        # Un mode allégé laissé allumé fausserait la répartition de tous les
        # tests suivants, et une tâche ajoutée par l'un apparaîtrait chez les
        # autres.
        conn.execute("DELETE FROM allegement")
        conn.execute("DELETE FROM tache WHERE ajoutee_par IS NOT NULL")
        # Les calendriers personnels naissent inactifs, faute d'URL : les
        # rallumer ici les ferait passer pour des sources en panne dans tous
        # les tests qui vérifient le bilan du matin.
        conn.execute("UPDATE source SET derniere_collecte = NULL, etat = 'ok', "
                     "url = NULL, active = (code NOT LIKE 'PERSO\\_%')")
        # La configuration d'une source se modifie par l'API : un test qui
        # change de groupe de TD ou écarte une UE ne doit pas décider du sort
        # des suivants. On la remet telle que les données de référence l'ont
        # posée.
        for code, configuration in _CONFIGURATIONS_INITIALES.items():
            conn.execute(
                "UPDATE source SET configuration = %s WHERE code = %s",
                (Json(configuration), code),
            )
        conn.execute("UPDATE utilisateur SET id_telegram = NULL, identifiant_apple = NULL")
        # Un test qui renouvelle son jeton d'abonnement ne doit pas invalider
        # l'URL de calendrier des suivants.
        conn.execute(
            "UPDATE utilisateur SET jeton_calendrier = CASE pseudo "
            "WHEN 'thomas' THEN %s ELSE %s END WHERE pseudo IN ('thomas', 'lorette')",
            (JETON_THOMAS, JETON_LORETTE),
        )
        # Le foyer : les comptes qu'un test a fait entrer repartent, et les deux
        # comptes de départ se retrouvent seuls dans un foyer neuf, à leurs droits
        # par défaut. Un membre retiré par un test redevient actif.
        conn.execute("DELETE FROM appareil")
        conn.execute("DELETE FROM invitation")
        conn.execute("UPDATE utilisateur SET id_foyer = NULL")
        # HDF-4 : la mémoire du foyer part avec lui.
        conn.execute("DELETE FROM memoire_foyer")
        conn.execute("DELETE FROM foyer")
        conn.execute("DELETE FROM source WHERE id_utilisateur IN ("
                     " SELECT id_utilisateur FROM utilisateur"
                     "  WHERE pseudo NOT IN ('thomas', 'lorette'))")
        conn.execute("DELETE FROM utilisateur WHERE pseudo NOT IN ('thomas', 'lorette')")
        conn.execute("UPDATE utilisateur SET actif = TRUE")
        conn.execute("SELECT amorcer_foyer()")
        conn.execute("SELECT appliquer_assignations()")
        # Les heures de chacun reprennent leurs valeurs par défaut, et aucun
        # rendez-vous n'est compté comme servi.
        conn.execute("DELETE FROM passage")
        conn.execute("UPDATE utilisateur SET heure_bilan = '07:00', heure_relance = '21:00', "
                     "heure_recap = '23:00', silence_debut = '23:30', silence_fin = '07:30', "
                     "orbe_vu_le = NULL")
        # En dernier : tout le ménage ci-dessus s'inscrit lui-même au journal.
        conn.execute("DELETE FROM evenement")
        conn.execute("UPDATE curseur SET dernier = 0")
    yield
