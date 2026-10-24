"""Des calendriers à la carte : qui on regarde, et ce qu'on en montre.

Le flux unique par compte ne suffisait plus. On veut voir les cours de l'autre
sans ses tâches, ses tâches sans son sport, et donner l'adresse à qui la
demande sans ouvrir le reste. D'où un calendrier composé : des personnes, des
familles de contenu, et un jeton à lui.

Ce qui est vérifié ici tient en deux questions. Le filtre montre-t-il
exactement ce qu'on a coché ? Un jeton composé reste-t-il borné à ce qu'il
déclare, même si on bricole l'URL ?
"""

from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import psycopg
import pytest

from api import abonnements
from tests.conftest import CLE_THOMAS, JETON_THOMAS, _url

PARIS = ZoneInfo("Europe/Paris")


def _sql(requete: str, *parametres):
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row,
                         autocommit=True) as conn:
        curseur = conn.execute(requete, parametres or None)
        return curseur.fetchall() if curseur.description else []


def _un(requete: str, *parametres):
    lignes = _sql(requete, *parametres)
    return next(iter(lignes[0].values())) if lignes else None


def _id(pseudo: str) -> int:
    return _un("SELECT id_utilisateur FROM utilisateur WHERE pseudo = %s", pseudo)


def _occupation(pseudo: str, type_: str, libelle: str, dans_jours: int = 1) -> None:
    debut = (datetime.now(PARIS) + timedelta(days=dans_jours)).replace(
        hour=9, minute=0, second=0, microsecond=0)
    _sql(
        """
        INSERT INTO occupation (id_utilisateur, id_source, type, libelle, periode)
        VALUES (%s, (SELECT id_source FROM source WHERE code = 'MANUELLE'),
                %s, %s, tstzrange(%s, %s::TIMESTAMPTZ + INTERVAL '2 hours', '[)'))
        """,
        _id(pseudo), type_, libelle, debut, debut)


@pytest.fixture(autouse=True)
def hote_connu():
    """Sans HOTE_PUBLIC, aucune adresse d'abonnement ne se construit."""
    from api.config import configuration

    conf = configuration()
    ancien = conf.hote_public
    conf.hote_public = "planif.example.ts.net:8443"
    yield
    conf.hote_public = ancien


@pytest.fixture
def deux_plannings(client, thomas):
    """Des cours et du travail pour chacun, plus les tâches du placement."""
    _occupation("thomas", "cours", "Compilation")
    _occupation("lorette", "cours", "Anatomie")
    _occupation("lorette", "autre", "Garde des enfants Martin", dans_jours=2)
    client.post("/planning/placer", headers=thomas)


# ---------------------------------------------------------------------------
# Le filtre                                                              NOT-6
# ---------------------------------------------------------------------------

def test_chaque_ligne_tombe_dans_une_famille(base):
    assert _un("SELECT contenu_de('occupation', 'cours')") == "cours"
    assert _un("SELECT contenu_de('occupation', 'travail')") == "travail"
    # Un calendrier personnel produit des occupations « autre » : c'est du perso.
    assert _un("SELECT contenu_de('occupation', 'autre')") == "perso"
    assert _un("SELECT contenu_de('tache', 'sport')") == "sport"
    assert _un("SELECT contenu_de('tache', 'menage')") == "taches"
    assert _un("SELECT contenu_de('proposition', 'trajet')") == "weekends"


def test_le_filtre_ne_rend_que_ce_qu_on_demande(client, thomas, deux_plannings):
    cours = _sql(
        "SELECT qui, libelle FROM planning_filtre(ARRAY[%s], ARRAY['cours'], "
        "       now() - INTERVAL '1 day', now() + INTERVAL '30 days')",
        _id("lorette"))

    assert [ligne["libelle"] for ligne in cours] == ["Anatomie"]
    assert cours[0]["qui"] == "Lorette"


def test_le_filtre_sait_prendre_deux_personnes(client, thomas, deux_plannings):
    lignes = _sql(
        "SELECT DISTINCT qui FROM planning_filtre(ARRAY[%s, %s], ARRAY['cours'], "
        "       now() - INTERVAL '1 day', now() + INTERVAL '30 days')",
        _id("thomas"), _id("lorette"))

    assert sorted(ligne["qui"] for ligne in lignes) == ["Lorette", "Thomas"]


# ---------------------------------------------------------------------------
# Composer, lire, supprimer                                       NOT-5, NOT-7
# ---------------------------------------------------------------------------

def test_composer_un_calendrier_et_s_y_abonner(client, thomas, deux_plannings):
    reponse = client.post("/moi/calendriers", headers=thomas,
                          params={"libelle": "Cours de Lorette",
                                  "personnes": "lorette", "contenus": "cours"})
    assert reponse.status_code == 201
    jeton = reponse.json()["jeton"]

    flux = client.get("/planning.ics", params={"cle": jeton})
    assert flux.status_code == 200
    texte = flux.content.decode()
    assert "Anatomie" in texte
    # Ni son babysitting, ni ses tâches, ni le planning de Thomas.
    assert "Garde des enfants" not in texte
    assert "Compilation" not in texte
    assert "X-WR-CALNAME:Cours de Lorette" in texte


def test_un_evenement_perso_garde_son_titre(client, thomas, deux_plannings):
    """NOT-10 : « autre : baby-sitting » n'apprend rien à personne."""
    texte = client.get("/planning.ics",
                       params={"cle": JETON_THOMAS, "qui": "lorette",
                               "quoi": "perso"}).content.decode()

    assert "SUMMARY:Garde des enfants Martin" in texte
    assert "autre" not in texte.lower().split("summary:")[1][:40]
    # Les catégories qui ont un nom, elles, le gardent.
    cours = client.get("/planning.ics",
                       params={"cle": JETON_THOMAS, "quoi": "cours"}).content.decode()
    assert "Cours : Compilation" in cours


def test_un_calendrier_a_deux_dit_de_qui_il_parle(client, thomas, deux_plannings):
    jeton = client.post("/moi/calendriers", headers=thomas,
                        params={"libelle": "Nos cours", "personnes": "thomas,lorette",
                                "contenus": "cours"}).json()["jeton"]

    texte = client.get("/planning.ics", params={"cle": jeton}).content.decode()

    # Deux cours à la même heure sans savoir qui les suit ne servirait à rien.
    assert "Lorette · Cours : Anatomie" in texte
    assert "Thomas · Cours : Compilation" in texte


def test_un_jeton_compose_ne_s_elargit_pas_dans_l_url(client, thomas, deux_plannings):
    jeton = client.post("/moi/calendriers", headers=thomas,
                        params={"libelle": "Cours seuls", "personnes": "lorette",
                                "contenus": "cours"}).json()["jeton"]

    # Le point de sécurité : donner « les cours de Lorette » à quelqu'un ne doit
    # pas lui donner de quoi demander tout le reste.
    texte = client.get("/planning.ics",
                       params={"cle": jeton, "qui": "tous",
                               "quoi": "cours,perso,taches"}).content.decode()

    assert "Garde des enfants" not in texte
    assert "Compilation" not in texte


def test_le_jeton_personnel_se_restreint_dans_l_url(client, thomas, deux_plannings):
    texte = client.get("/planning.ics",
                       params={"cle": JETON_THOMAS, "qui": "lorette",
                               "quoi": "perso"}).content.decode()

    assert "Garde des enfants Martin" in texte
    assert "Anatomie" not in texte
    assert "Compilation" not in texte


def test_une_personne_inconnue_est_refusee(client):
    reponse = client.get("/planning.ics",
                         params={"cle": JETON_THOMAS, "qui": "kevin"})
    assert reponse.status_code == 400
    assert reponse.json()["code"] == "personne_inconnue"


def test_un_contenu_inconnu_est_refuse(client):
    reponse = client.get("/planning.ics",
                         params={"cle": JETON_THOMAS, "quoi": "courses"})
    assert reponse.status_code == 400
    assert reponse.json()["code"] == "contenu_inconnu"


def test_supprimer_un_calendrier_coupe_son_adresse(client, thomas):
    cree = client.post("/moi/calendriers", headers=thomas,
                       params={"libelle": "À jeter", "personnes": "moi",
                               "contenus": "sport"}).json()

    client.delete(f"/moi/calendriers/{cree['id_calendrier']}", headers=thomas)

    assert client.get("/planning.ics", params={"cle": cree["jeton"]}).status_code == 401
    # Le jeton personnel, lui, continue de répondre.
    assert client.get("/planning.ics", params={"cle": JETON_THOMAS}).status_code == 200


def test_on_ne_supprime_pas_le_calendrier_d_un_autre(client, thomas, lorette):
    cree = client.post("/moi/calendriers", headers=lorette,
                       params={"libelle": "Le sien", "personnes": "moi",
                               "contenus": "cours"}).json()

    reponse = client.delete(f"/moi/calendriers/{cree['id_calendrier']}", headers=thomas)

    assert reponse.status_code == 404
    assert client.get("/planning.ics", params={"cle": cree["jeton"]}).status_code == 200


def test_chacun_peut_regarder_l_autre(client, lorette, deux_plannings):
    # On vit à deux : Lorette compose un calendrier des cours de Thomas.
    jeton = client.post("/moi/calendriers", headers=lorette,
                        params={"libelle": "Cours de Thomas", "personnes": "thomas",
                                "contenus": "cours"}).json()["jeton"]

    texte = client.get("/planning.ics", params={"cle": jeton}).content.decode()
    assert "Compilation" in texte


def test_un_calendrier_vide_est_refuse(client, thomas):
    reponse = client.post("/moi/calendriers", headers=thomas,
                          params={"libelle": "Rien", "personnes": "moi",
                                  "contenus": ""})
    assert reponse.status_code == 400


def test_le_jeton_d_un_calendrier_n_ouvre_rien_d_autre(client, thomas):
    jeton = client.post("/moi/calendriers", headers=thomas,
                        params={"libelle": "Lecture seule", "personnes": "moi",
                                "contenus": "taches"}).json()["jeton"]

    # Même règle que pour le jeton personnel : cette adresse vit en clair dans
    # un téléphone, elle ne doit ouvrir que la lecture d'un planning (UTI-2).
    assert client.get("/moi", headers={"X-Cle-Api": jeton}).status_code == 401
    assert client.get("/planning.ics", params={"cle": CLE_THOMAS}).status_code == 401


# ---------------------------------------------------------------------------
# Les écrans du bot                                                      NOT-9
# ---------------------------------------------------------------------------

def _rappels(ecran) -> list[str]:
    return [rappel for rangee in ecran.boutons for _, rappel in rangee]


def test_supprimer_un_calendrier(client, thomas):
    moi = _id("thomas")
    cree = abonnements.creer_calendrier(moi, "Mon sport", [moi], ["sport"])

    reponse = client.delete(f"/moi/calendriers/{cree['id_calendrier']}", headers=thomas)

    assert reponse.status_code == 200
    assert abonnements.calendriers_de(moi) == []
    # Son adresse cesse aussitôt de répondre.
    assert client.get("/planning.ics", params={"cle": cree["jeton"]}).status_code == 401


