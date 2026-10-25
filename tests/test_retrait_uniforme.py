"""Le stock d'uniforme est retiré, le linge ordinaire continue.     (migration 031)

Le code retiré se retrouve sous le tag git « avant-nettoyage ». Ces tests
vérifient surtout ce qui devait rester debout : le placement ne consultait plus
le stock qu'en passant, et le trigger de validation portait le séchage de
l'uniforme au milieu des enchaînements.
"""

import psycopg

from tests.conftest import _url, id_de


def occurrences(client, thomas, code: str, statuts=("a_placer", "planifiee", "notifiee")):
    toutes = client.get("/occurrences", headers=thomas,
                        params={"statut": list(statuts)}).json()
    return [o for o in toutes if o["id_tache"] == id_de(code)]


def test_plus_de_lessive_de_travail(client, thomas):
    reponse = client.post("/planning/placer", headers=thomas)
    assert reponse.status_code == 200

    assert occurrences(client, thomas, "LESSIVE_TRAVAIL") == []


def test_le_stock_a_quitte_le_schema_vivant(base):
    with psycopg.connect(_url()) as conn:
        vivantes = {nom for (nom,) in conn.execute(
            "SELECT table_name FROM information_schema.tables "
            " WHERE table_schema = 'public'")}
        archivees = {nom for (nom,) in conn.execute(
            "SELECT table_name FROM information_schema.tables "
            " WHERE table_schema = 'archive'")}
        colonnes = {nom for (nom,) in conn.execute(
            "SELECT column_name FROM information_schema.columns "
            " WHERE table_schema = 'public' AND table_name = 'tache'")}

    assert not {"article_travail", "mouvement_stock", "v_stock"} & vivantes
    # Les données ne sont pas perdues, seulement rangées.
    assert {"article_travail", "mouvement_stock"} <= archivees
    assert "lave_uniforme" not in colonnes
    # La machine a suivi en octobre 2026 : elle est dans la description des lessives.
    assert "utilise_machine" not in colonnes


def test_la_lessive_de_blanc_s_enchaine_toujours(client, thomas):
    client.post("/planning/placer", headers=thomas)
    lessive = min(occurrences(client, thomas, "LESSIVE_BLANC"),
                  key=lambda o: o["echeance_min"])

    reponse = client.post(f"/occurrences/{lessive['id_occurrence']}/valider",
                          headers=thomas, json={})
    assert reponse.status_code == 200, reponse.text

    # Le trigger de validation a perdu son bloc sur l'uniforme : l'étendage,
    # lui, doit toujours suivre la lessive.
    assert occurrences(client, thomas, "ETENDRE_LINGE")


def test_les_routes_du_stock_n_existent_plus(client, thomas):
    assert client.get("/stock", headers=thomas).status_code == 404
