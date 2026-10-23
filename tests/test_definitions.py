"""Une définition par fonction, et une seule.

Jusqu'à la migration 047, les fonctions étaient réécrites de migration en
migration : `placer_taches` existait en trois versions dans trois fichiers, et
la bonne était celle du dernier à en parler. Rejouer un vieux fichier, ou en
oublier un, installait une ancienne version sans que rien ne le dise.

Elles vivent maintenant dans `sql/definitions/`, un fichier par fonction, et ce
dossier est rechargé à chaque passage des migrations. Ces tests tiennent le
dossier et la base d'accord : tout ce qui existe en base a son fichier, tout
fichier donne ce qui existe en base, et recharger remet tout en place.
"""

import re

import psycopg
import pytest

from tests.conftest import RACINE, _url, charger_definitions

DOSSIER = RACINE / "sql" / "definitions"

# L'empreinte de chaque fonction, vue et déclencheur, commentaire compris. Les
# fonctions apportées par une extension (btree_gist) ne sont pas les nôtres.
CLICHE = """
    SELECT 'fonction ' || p.proname,
           md5(pg_get_functiondef(p.oid))
           || md5(COALESCE(obj_description(p.oid, 'pg_proc'), ''))
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND NOT EXISTS (SELECT 1 FROM pg_depend d
                        WHERE d.objid = p.oid AND d.deptype = 'e')
    UNION ALL
    SELECT 'vue ' || c.relname,
           md5(pg_get_viewdef(c.oid))
           || md5(COALESCE(obj_description(c.oid, 'pg_class'), ''))
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind = 'v'
    UNION ALL
    SELECT 'déclencheur ' || t.tgname, md5(pg_get_triggerdef(t.oid))
      FROM pg_trigger t WHERE NOT t.tgisinternal
     ORDER BY 1
"""


def cliche(url: str | None = None) -> dict[str, str]:
    with psycopg.connect(url or _url(), autocommit=True) as conn:
        return dict(conn.execute(CLICHE).fetchall())


def _noms(genre: str) -> list[str]:
    return sorted(nom.split(" ", 1)[1] for nom in cliche() if nom.startswith(genre))


@pytest.fixture
def conn():
    with psycopg.connect(_url(), autocommit=True) as connexion:
        yield connexion
        # Quoi qu'un test ait abîmé, les suivants retrouvent la base du dépôt.
        charger_definitions(connexion)


def test_chaque_fonction_a_son_fichier_et_rien_de_plus():
    en_base = _noms("fonction")
    en_fichiers = sorted(f.stem for f in (DOSSIER / "fonctions").glob("*.sql"))

    # Deux fois le même nom en base, c'est une signature changée sans avoir
    # retiré l'ancienne : PostgreSQL garde alors les deux.
    assert len(en_base) == len(set(en_base)), "une fonction existe sous deux signatures"
    assert en_base == en_fichiers


def test_un_fichier_ne_definit_que_sa_fonction():
    for fichier in sorted((DOSSIER / "fonctions").glob("*.sql")):
        definies = re.findall(r"^CREATE OR REPLACE FUNCTION\s+(\w+)",
                              fichier.read_text(), re.M)
        assert definies == [fichier.stem], fichier.name


def test_chaque_vue_a_son_fichier():
    en_fichiers = sorted(f.stem.split("_", 1)[1]
                         for f in (DOSSIER / "vues").glob("[0-9][0-9]_*.sql"))

    assert _noms("vue") == en_fichiers


def test_chaque_declencheur_est_dans_le_fichier():
    ecrits = re.findall(r"^CREATE OR REPLACE TRIGGER\s+(\w+)",
                        (DOSSIER / "declencheurs.sql").read_text(), re.M)

    assert _noms("déclencheur") == sorted(ecrits)


def test_recharger_ne_change_rien(conn):
    avant = cliche()

    charger_definitions(conn)
    charger_definitions(conn)

    assert cliche() == avant


def test_recharger_repare_ce_qui_a_ete_abime(conn):
    """Ce qui rend une vieille migration inoffensive.

    Une fonction remplacée par une autre, une vue disparue, un déclencheur
    retiré : c'est ce que laissait le rejeu d'un ancien fichier.
    """
    avant = cliche()
    conn.execute("CREATE OR REPLACE FUNCTION reequilibrer(p_jours INTEGER DEFAULT 7) "
                 "RETURNS INTEGER LANGUAGE sql AS 'SELECT -1'")
    conn.execute("DROP VIEW v_taches_en_retard")
    conn.execute("DROP TRIGGER occupation_reverifier_propositions ON occupation")
    assert cliche() != avant

    charger_definitions(conn)

    assert cliche() == avant


def test_une_definition_fausse_ne_laisse_rien_a_moitie(conn):
    avant = cliche()

    # Le chargement retire les vues avant de les recréer. S'il casse en route,
    # tout doit revenir, vues comprises : c'est le rôle de la transaction.
    with pytest.raises(psycopg.Error), conn.transaction():
        conn.execute("SET LOCAL check_function_bodies = off")
        conn.execute("DROP VIEW v_taches_en_retard")
        conn.execute("CREATE VIEW v_taches_en_retard AS SELECT * FROM table_inconnue")

    assert cliche() == avant
