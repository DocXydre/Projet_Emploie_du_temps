"""sql/SCHEMA.md dit le schéma tel que les migrations le font.

Le dessin est généré depuis la base de test, construite par les mêmes
migrations que la production. Une migration qui ajoute une table, ou un
dessin qu'on a oublié de refaire, fait échouer ce test.
"""

import psycopg

from outils import schema
from tests.conftest import _url


def _base_de_test():
    return psycopg.connect(_url(), row_factory=psycopg.rows.dict_row)


def test_chaque_table_est_rangee_dans_un_domaine(base):
    with _base_de_test() as conn:
        tables, _, _ = schema.lire(conn)

    assert schema.non_rangees(tables) == set(), "à ranger dans DOMAINES, outils/schema.py"
    # Et aucun domaine ne cite une table qui n'existe plus.
    citees = {t for _, membres in schema.DOMAINES.values() for t in membres}
    assert citees <= set(tables), citees - set(tables)


def test_le_schema_publie_est_a_jour(base):
    with _base_de_test() as conn:
        attendu = schema.generer(conn)

    assert schema.FICHIER.read_text() == attendu, \
        "sql/SCHEMA.md n'est plus à jour : python -m outils.schema"
