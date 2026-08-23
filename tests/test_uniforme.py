"""Consommation de l'uniforme : un service porté est un vêtement en moins.

Le stock n'avait jamais bougé depuis la mise en service, pour une raison
simple : la fonction existait et personne ne l'appelait. La projection de
lessive tournait donc sur un stock éternellement plein, et n'a jamais rien
déclenché.

Deux règles se vérifient ici. Un t-shirt part au sale à chaque journée
travaillée. Un pantalon, une journée travaillée sur deux — et non un jour du
calendrier sur deux : travailler lundi puis jeudi doit le salir au second
service, pas selon la date qu'il portait.
"""

from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import psycopg

from tests.conftest import _url

PARIS = ZoneInfo("Europe/Paris")


def sql(requete: str, *parametres):
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row,
                         autocommit=True) as conn:
        curseur = conn.execute(requete, parametres or None)
        return curseur.fetchall() if curseur.description else []


def un(requete: str, *parametres):
    lignes = sql(requete, *parametres)
    return next(iter(lignes[0].values())) if lignes else None


def travailler(client, entete, dans_jours: int) -> None:
    """Un service de 17h à 23h, ce jour-là."""
    base = datetime.now(PARIS) + timedelta(days=dans_jours)
    client.post("/occupations", headers=entete, json={
        "type": "travail", "libelle": "Shift",
        "debut": base.replace(hour=17, minute=0, second=0, microsecond=0).isoformat(),
        "fin": base.replace(hour=23, minute=0, second=0, microsecond=0).isoformat(),
    })


def jour(dans_jours: int):
    return (datetime.now(PARIS) + timedelta(days=dans_jours)).date()


def propres() -> dict[str, int]:
    return {ligne["code"]: ligne["quantite_propre"]
            for ligne in sql("SELECT code, quantite_propre FROM article_travail")}


def portees() -> dict[str, int]:
    return {ligne["code"]: ligne["journees_portees"]
            for ligne in sql("SELECT code, journees_portees FROM article_travail")}


# ---------------------------------------------------------------------------
# Le t-shirt : une journée, un t-shirt
# ---------------------------------------------------------------------------

def test_une_journee_travaillee_salit_un_tshirt(client, thomas):
    travailler(client, thomas, -1)
    avant = propres()["TSHIRT"]

    assert un("SELECT consommer_uniforme(%s)", jour(-1)) >= 1
    assert propres()["TSHIRT"] == avant - 1


def test_un_jour_sans_service_ne_salit_rien(client, thomas):
    avant = propres()
    assert un("SELECT consommer_uniforme(%s)", jour(-1)) == 0
    assert propres() == avant


def test_compter_deux_fois_le_meme_jour_ne_salit_qu_une_fois(client, thomas):
    travailler(client, thomas, -1)
    un("SELECT consommer_uniforme(%s)", jour(-1))
    avant = propres()["TSHIRT"]

    # R101 : le Mac dort, l'ordonnanceur saute des jours et rattrape. Sans
    # cette garde, rattraper salirait deux t-shirts pour un seul service.
    assert un("SELECT consommer_uniforme(%s)", jour(-1)) == 0
    assert propres()["TSHIRT"] == avant


# ---------------------------------------------------------------------------
# Le pantalon : une journée sur deux, comptées et non datées
# ---------------------------------------------------------------------------

def test_le_pantalon_tient_deux_journees(client, thomas):
    for recul in (-2, -1):
        travailler(client, thomas, recul)

    avant = propres()["PANTALON"]
    un("SELECT consommer_uniforme(%s)", jour(-2))
    assert propres()["PANTALON"] == avant, "trop tôt : une seule journée portée"
    assert portees()["PANTALON"] == 1

    un("SELECT consommer_uniforme(%s)", jour(-1))
    assert propres()["PANTALON"] == avant - 1
    assert portees()["PANTALON"] == 0


def test_deux_journees_espacees_salissent_quand_meme(client, thomas):
    # R100 : « une journée travaillée sur deux », et non « un jour du calendrier
    # sur deux ». Travailler lundi puis jeudi doit salir au second service.
    for recul in (-5, -1):
        travailler(client, thomas, recul)

    avant = propres()["PANTALON"]
    un("SELECT consommer_uniforme(%s)", jour(-5))
    un("SELECT consommer_uniforme(%s)", jour(-1))

    assert propres()["PANTALON"] == avant - 1


def test_les_jours_non_travailles_ne_comptent_pas(client, thomas):
    travailler(client, thomas, -3)
    un("SELECT rattraper_uniforme()")

    # Trois jours écoulés, un seul travaillé : le pantalon n'a été porté
    # qu'une fois.
    assert portees()["PANTALON"] == 1


# ---------------------------------------------------------------------------
# Rattrapage
# ---------------------------------------------------------------------------

def test_le_rattrapage_couvre_les_jours_manques(client, thomas):
    for recul in (-4, -3, -2):
        travailler(client, thomas, recul)

    avant = propres()
    sales = un("SELECT rattraper_uniforme()")

    # Trois services : trois t-shirts, et un pantalon (le second service).
    assert sales >= 3
    assert propres()["TSHIRT"] == avant["TSHIRT"] - 3
    assert propres()["PANTALON"] == avant["PANTALON"] - 1


def test_le_rattrapage_est_rejouable(client, thomas):
    for recul in (-3, -2):
        travailler(client, thomas, recul)
    un("SELECT rattraper_uniforme()")
    apres = propres()

    assert un("SELECT rattraper_uniforme()") == 0
    assert propres() == apres


def test_aujourd_hui_n_est_pas_encore_compte(client, thomas):
    travailler(client, thomas, 0)
    avant = propres()

    # Le service du soir n'est pas fini. Compter un t-shirt le matin pour un
    # shift de 17h reviendrait à annoncer une lessive qu'on n'a pas méritée.
    un("SELECT rattraper_uniforme()")
    assert propres() == avant


# ---------------------------------------------------------------------------
# Le lavage remet le compteur à zéro
# ---------------------------------------------------------------------------

def test_un_retour_propre_remet_le_compteur_a_zero(client, thomas):
    travailler(client, thomas, -1)
    un("SELECT consommer_uniforme(%s)", jour(-1))
    assert portees()["PANTALON"] == 1

    client.post("/stock/PANTALON/mouvement", headers=thomas,
                json={"type": "retour_propre", "quantite": 1})

    # C'est le sens même de « propre » : le pantalon repart pour deux services.
    assert portees()["PANTALON"] == 0


# ---------------------------------------------------------------------------
# Par l'API, et l'effet sur la lessive
# ---------------------------------------------------------------------------

def test_la_consommation_passe_par_l_api(client, thomas):
    for recul in (-2, -1):
        travailler(client, thomas, recul)

    reponse = client.post("/stock/consommer", headers=thomas)
    assert reponse.status_code == 200
    assert reponse.json()["articles_sales"] >= 2


def test_le_stock_qui_baisse_avance_la_lessive(client, thomas):
    for recul in range(-3, 0):
        travailler(client, thomas, recul)
    for avance in range(1, 4):
        travailler(client, thomas, avance)

    client.post("/stock/consommer", headers=thomas)
    projection = client.get("/stock/projection", headers=thomas).json()

    # Le stock a baissé pour de bon : la projection doit voir venir la rupture,
    # ce qu'elle ne pouvait pas faire sur un stock éternellement plein.
    assert projection["ruptures"] or propres()["TSHIRT"] < 3
