"""Le script qui applique les migrations, éprouvé pour de bon.

`sql/appliquer.sh` est le seul code du projet qui tourne en production sans
passer par l'API, et il n'avait aucun test. Il en a maintenant, parce qu'il
portait trois défauts qui ne se voyaient qu'au pire moment.

Rejouer une vieille migration cassait le placement. Quinze fonctions sont
réécrites d'une migration à l'autre, et le script rejouait un fichier dès qu'un
caractère y changeait, sans rejouer ceux qui l'avaient repris depuis. Corriger
un commentaire dans `003_fonctions.sql` réinstallait un `placer_taches` vieux de
quarante migrations.

Une migration qui échouait au milieu restait à moitié appliquée.

Et « NON rejouable » contient le mot « rejouable » : les deux migrations qui
effacent des lignes passaient pour rejouables.

Depuis, les fonctions ont quitté les migrations pour `sql/definitions/`, que le
script recharge à chaque passage. La fin de ce fichier vérifie ce chargement, le
refus des migrations qui définissent encore une fonction, et les rattrapages de
`sql/apres/`.

Ces tests lancent le vrai script, contre une base à part, avec un faux `docker`
qui redirige vers le PostgreSQL des tests. Ils demandent `bash` et `psql` sur la
machine, et sont sautés sinon.
"""

import os
import shutil
import subprocess
from pathlib import Path

import psycopg
import pytest

from tests.conftest import RACINE
from tests.conftest import _url as url_des_tests
from tests.test_definitions import cliche

BASE = "planif_migrations"
HOTE = os.environ.get("DB_HOTE", "localhost")
PORT = os.environ.get("DB_PORT", "5432")
QUI = os.environ.get("POSTGRES_USER", "planif")
SECRET = os.environ.get("POSTGRES_PASSWORD", "planif")

pytestmark = pytest.mark.skipif(
    shutil.which("psql") is None or shutil.which("bash") is None,
    reason="demande bash et psql sur la machine")


def _url(base: str) -> str:
    return f"postgresql://{QUI}:{SECRET}@{HOTE}:{PORT}/{base}"


def _sql(requete: str):
    with psycopg.connect(_url(BASE), autocommit=True) as conn:
        curseur = conn.execute(requete)
        return curseur.fetchall() if curseur.description else []


@pytest.fixture(scope="module")
def depot(tmp_path_factory) -> Path:
    """Une copie du dossier `sql/`, une base neuve, et le script passé une fois."""
    racine = tmp_path_factory.mktemp("depot")
    shutil.copytree(RACINE / "sql", racine / "sql")
    (racine / ".env").write_text(
        f"POSTGRES_DB={BASE}\nPOSTGRES_USER={QUI}\nPOSTGRES_PASSWORD={SECRET}\n")

    # Le script appelle « docker exec -i planif-db psql ... ». Ce faux docker
    # jette les trois premiers mots et parle au PostgreSQL des tests.
    faux = racine / "faux"
    faux.mkdir()
    (faux / "docker").write_text(
        f'#!/bin/bash\nshift 3\nexec psql -h {HOTE} -p {PORT} "$@"\n')
    (faux / "docker").chmod(0o755)

    with psycopg.connect(_url("postgres"), autocommit=True) as conn:
        conn.execute(f"DROP DATABASE IF EXISTS {BASE}")
        conn.execute(f"CREATE DATABASE {BASE}")

    premier = _lancer(racine)
    assert premier.returncode == 0, premier.stdout + premier.stderr
    yield racine

    with psycopg.connect(_url("postgres"), autocommit=True) as conn:
        conn.execute(f"DROP DATABASE IF EXISTS {BASE} WITH (FORCE)")


def _lancer(racine: Path, *arguments: str) -> subprocess.CompletedProcess:
    environnement = {**os.environ, "PGPASSWORD": SECRET,
                     "PATH": f"{racine / 'faux'}:{os.environ['PATH']}"}
    return subprocess.run(
        ["bash", str(racine / "sql" / "appliquer.sh"), *arguments],
        capture_output=True, text=True, env=environnement, timeout=180)


class _Retouche:
    """Modifie un fichier le temps d'un test, et le rend tel qu'il était."""

    def __init__(self, fichier: Path, ajout: str = "\n-- retouche\n"):
        self.fichier, self.ajout = fichier, ajout

    def __enter__(self):
        self.avant = self.fichier.read_text()
        self.fichier.write_text(self.avant + self.ajout)
        return self

    def __exit__(self, *_):
        self.fichier.write_text(self.avant)


def test_un_second_passage_ne_fait_rien(depot):
    sortie = _lancer(depot).stdout

    assert "0 migration(s) appliquée(s), 0 rejouée(s)." in sortie


def test_retoucher_une_vieille_migration_ne_casse_pas_le_placement(depot):
    """Le défaut d'origine, rejoué tel quel.

    Un commentaire ajouté à 003 suffisait : le script réinstallait l'ancien
    `placer_taches`, qui appelle une fonction supprimée depuis.
    """
    with _Retouche(depot / "sql" / "003_fonctions.sql"):
        passage = _lancer(depot)

        assert passage.returncode == 0
        # Il refuse, et il dit pourquoi, avec le nom de ce qui a été repris.
        assert "003_fonctions.sql a changé" in passage.stdout
        assert "placer_taches (repris par" in passage.stdout
        assert "↻ 003_fonctions.sql" not in passage.stdout

        # La preuve qui compte : le placement tourne encore.
        assert _sql("SELECT placer_taches()")[0][0] is not None


def test_le_refus_se_repete_tant_que_rien_n_est_decide(depot):
    # Une divergence qu'on ne signalerait qu'une fois finirait oubliée.
    with _Retouche(depot / "sql" / "003_fonctions.sql"):
        _lancer(depot)
        assert "003_fonctions.sql a changé" in _lancer(depot).stdout


def test_adopter_prend_acte_sans_rien_rejouer(depot):
    # Pour la virgule corrigée dans un commentaire : rien à exécuter, mais il
    # faut pouvoir faire taire l'avertissement.
    fichier = depot / "sql" / "003_fonctions.sql"
    avant = _sql("SELECT empreinte FROM schema_migration "
                 " WHERE fichier = '003_fonctions.sql'")[0][0]
    with _Retouche(fichier):
        adoption = _lancer(depot, "--adopter", "003_fonctions.sql")
        assert adoption.returncode == 0
        assert "rien n'a été rejoué" in adoption.stdout

        suite = _lancer(depot).stdout
        assert "a changé" not in suite
        assert _sql("SELECT placer_taches()")[0][0] is not None

    # Le fichier retrouve son contenu : l'empreinte d'origine aussi.
    _lancer(depot, "--adopter", "003_fonctions.sql")
    assert _sql("SELECT empreinte FROM schema_migration "
                " WHERE fichier = '003_fonctions.sql'")[0][0] == avant


def test_la_derniere_migration_se_rejoue_toujours(depot):
    # Ce à quoi sert « rejouable » : corriger une migration qu'on vient de
    # livrer. Personne ne l'a reprise, donc rien ne s'y oppose.
    derniere = sorted((depot / "sql").glob("0[0-9][0-9]_*.sql"))[-1]
    with _Retouche(derniere):
        sortie = _lancer(depot).stdout

    assert f"↻ {derniere.name} (modifié, rejoué)" in sortie


def test_une_migration_que_personne_n_a_reprise_se_rejoue(depot):
    # Les poubelles et les draps : des données, aucune fonction. Rien de plus
    # récent n'y touche, donc le fichier reste rejouable même trois mois après.
    with _Retouche(depot / "sql" / "040_poubelles_et_draps.sql"):
        sortie = _lancer(depot).stdout

    assert "↻ 040_poubelles_et_draps.sql (modifié, rejoué)" in sortie


def test_une_migration_qui_casse_ne_laisse_rien(depot):
    fautive = depot / "sql" / "099_essai.sql"
    fautive.write_text("-- essai\n"
                       "CREATE TABLE essai_a (x INTEGER);\n"
                       "INSERT INTO essai_a VALUES (1);\n"
                       "SELECT 1 / 0;\n"
                       "CREATE TABLE essai_b (y INTEGER);\n")
    try:
        passage = _lancer(depot)
    finally:
        fautive.unlink()

    # Le script s'arrête, et le dit par son code de sortie : c'est ce que le
    # déploiement regarde.
    assert passage.returncode != 0
    # Rien de la première moitié n'est resté.
    assert _sql("SELECT count(*) FROM pg_tables WHERE tablename LIKE 'essai_%'")[0][0] == 0
    assert _sql("SELECT count(*) FROM schema_migration "
                " WHERE fichier = '099_essai.sql'")[0][0] == 0


@pytest.mark.parametrize("nom", ["042_relire_les_billets_a_venir.sql",
                                 "043_relire_vraiment_les_billets.sql"])
def test_non_rejouable_ne_veut_pas_dire_rejouable(depot, nom):
    # Ces deux fichiers effacent la mémoire des courriels et les absences à
    # venir. Leur en-tête dit « NON rejouable », qui contient le mot cherché.
    with _Retouche(depot / "sql" / nom):
        sortie = _lancer(depot).stdout

    assert f"↻ {nom}" not in sortie
    assert f"{nom} a changé mais ne se rejoue pas" in sortie


# ---------------------------------------------------------------------------
# Les définitions : une par fonction, rechargées à chaque passage
# ---------------------------------------------------------------------------

def test_modifier_une_definition_suffit(depot):
    # Plus de migration à écrire pour changer une fonction : on corrige son
    # fichier, et le passage suivant l'installe.
    fichier = depot / "sql" / "definitions" / "fonctions" / "reequilibrer.sql"
    avant = fichier.read_text()
    fichier.write_text(avant.replace("v_liberees INTEGER;",
                                     "v_liberees INTEGER;  -- retouche", 1))
    try:
        passage = _lancer(depot)
        assert passage.returncode == 0, passage.stdout + passage.stderr
        assert "✓ définitions" in passage.stdout
        assert "retouche" in _sql("SELECT pg_get_functiondef('reequilibrer'::regproc)")[0][0]
    finally:
        fichier.write_text(avant)

    _lancer(depot)
    assert "retouche" not in _sql("SELECT pg_get_functiondef('reequilibrer'::regproc)")[0][0]


def test_une_definition_fausse_arrete_le_passage_sans_rien_casser(depot):
    avant = cliche(_url(BASE))
    # Le dernier fichier chargé : tout le reste est déjà passé quand il casse.
    with _Retouche(depot / "sql" / "definitions" / "declencheurs.sql",
                   "\nCREATE TRIGGER essai AFTER INSERT ON table_inconnue "
                   "FOR EACH ROW EXECUTE FUNCTION trg_occurrence_close();\n"):
        passage = _lancer(depot)

    assert passage.returncode != 0
    assert cliche(_url(BASE)) == avant


def test_une_migration_recente_ne_definit_plus_de_fonction(depot):
    fautive = depot / "sql" / "098_essai.sql"
    fautive.write_text("-- essai\n"
                       "CREATE TABLE essai_c (x INTEGER);\n"
                       "CREATE OR REPLACE FUNCTION essai_f() RETURNS INTEGER\n"
                       "LANGUAGE sql AS 'SELECT 1';\n")
    try:
        passage = _lancer(depot)
    finally:
        fautive.unlink()

    # Refusée avant d'avoir rien appliqué, avec l'adresse où ranger la fonction.
    assert passage.returncode != 0
    assert "098_essai.sql : essai_f" in passage.stdout
    assert "sql/definitions/" in passage.stdout
    assert _sql("SELECT count(*) FROM pg_tables WHERE tablename = 'essai_c'")[0][0] == 0


def test_une_migration_recente_peut_retirer_une_fonction(depot):
    # Changer une signature demande de retirer l'ancienne : c'est permis, et
    # c'est même le seul rôle qui reste aux migrations du côté des fonctions.
    migration = depot / "sql" / "098_essai.sql"
    migration.write_text("-- essai\n"
                         "-- CREATE FUNCTION cité dans un commentaire, sans effet.\n"
                         "DROP FUNCTION IF EXISTS fonction_jamais_vue();\n")
    try:
        passage = _lancer(depot)
    finally:
        migration.unlink()
        _sql("DELETE FROM schema_migration WHERE fichier = '098_essai.sql'")

    assert passage.returncode == 0, passage.stdout + passage.stderr
    assert "→ 098_essai.sql" in passage.stdout


def test_un_rattrapage_passe_une_fois_avec_les_fonctions_a_jour(depot):
    """`sql/apres/` : ce qu'une migration faisait en appelant sa propre fonction."""
    fonction = depot / "sql" / "definitions" / "fonctions" / "essai_apres.sql"
    fonction.write_text("CREATE OR REPLACE FUNCTION essai_apres() RETURNS INTEGER\n"
                        "LANGUAGE sql AS 'SELECT 42';\n")
    rattrapage = depot / "sql" / "apres" / "900_essai.sql"
    rattrapage.parent.mkdir(exist_ok=True)
    rattrapage.write_text("CREATE TABLE essai_r AS SELECT essai_apres() AS x;\n")
    try:
        premier = _lancer(depot)
        assert premier.returncode == 0, premier.stdout + premier.stderr
        assert "→ apres/900_essai.sql" in premier.stdout
        # La fonction n'existait dans aucune migration : le rattrapage l'a
        # trouvée parce qu'il passe après les définitions.
        assert _sql("SELECT x FROM essai_r")[0][0] == 42

        # Une fois, pas deux : la table existe déjà, un second essai échouerait.
        second = _lancer(depot)
        assert second.returncode == 0
        assert "· apres/900_essai.sql (déjà appliqué)" in second.stdout

        # Et un rattrapage retouché ne repart pas tout seul.
        with _Retouche(rattrapage):
            troisieme = _lancer(depot)
        assert "apres/900_essai.sql a changé mais ne se rejoue pas" in troisieme.stdout
    finally:
        fonction.unlink()
        shutil.rmtree(rattrapage.parent)
        _sql("DROP TABLE IF EXISTS essai_r")
        _sql("DROP FUNCTION IF EXISTS essai_apres()")
        _sql("DELETE FROM schema_migration WHERE fichier LIKE 'apres/%'")


def test_le_script_et_les_tests_construisent_la_meme_base(depot):
    # Les tests chargent le SQL par `conftest`, le serveur par ce script. Si
    # les deux ordres divergeaient, les tests vérifieraient une base que la
    # production n'a pas.
    passage = _lancer(depot)
    assert passage.returncode == 0, passage.stdout + passage.stderr

    assert cliche(_url(BASE)) == cliche(url_des_tests())
