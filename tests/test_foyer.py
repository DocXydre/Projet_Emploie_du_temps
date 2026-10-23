"""Le foyer, les invitations, les droits sur les tâches et les appareils (lot 1)."""

import hashlib

import psycopg
import pytest

from tests.conftest import _url

MOT_DE_PASSE = "un-long-mot-de-passe"


def _sql(requete: str, params: tuple = ()) -> list[tuple]:
    with psycopg.connect(_url(), autocommit=True) as conn:
        curseur = conn.execute(requete, params)
        return curseur.fetchall() if curseur.description else []


def _id(pseudo: str) -> int:
    return _sql("SELECT id_utilisateur FROM utilisateur WHERE pseudo = %s", (pseudo,))[0][0]


def _liberer_une_place(client, thomas, lorette) -> None:
    """Le foyer de test est plein à deux : Lorette en sort pour faire de la place."""
    assert client.post("/foyer/quitter", headers=lorette).status_code == 200


def _inviter(client, thomas) -> str:
    reponse = client.post("/foyer/invitations", headers=thomas)
    assert reponse.status_code == 201, reponse.text
    return reponse.json()["code"]


def _rejoindre(client, code: str, pseudo: str = "camille", mot_de_passe: str = MOT_DE_PASSE):
    return client.post(f"/invitations/{code}/accepter",
                       json={"pseudo": pseudo, "mot_de_passe": mot_de_passe})


# ---------------------------------------------------------------------------
# Le foyer de départ
# ---------------------------------------------------------------------------

def test_les_deux_comptes_sont_dans_le_meme_foyer(client, thomas, lorette):
    foyer = client.get("/foyer", headers=thomas).json()
    assert [m["pseudo"] for m in foyer["membres"]] == ["thomas", "lorette"]
    assert foyer["membres"][0]["administrateur"] is True
    assert foyer["je_suis_admin"] is True
    assert foyer["places_libres"] == 0
    assert (foyer["ajout_taches"], foyer["modif_taches"]) == ("tous", "tous")

    vu_par_lorette = client.get("/foyer", headers=lorette).json()
    assert vu_par_lorette["id_foyer"] == foyer["id_foyer"]
    assert vu_par_lorette["je_suis_admin"] is False
    assert vu_par_lorette["je_peux_ajouter"] is True


def test_amorcer_le_foyer_ne_refait_rien(client):
    assert _sql("SELECT amorcer_foyer()")[0][0] is None
    assert _sql("SELECT count(*) FROM foyer")[0][0] == 1


def test_seul_l_admin_regle_le_foyer(client, thomas, lorette):
    refus = client.patch("/foyer", headers=lorette, json={"nom": "Chez nous"})
    assert refus.status_code == 403

    reponse = client.patch("/foyer", headers=thomas,
                           json={"nom": "Chez nous", "modif_taches": "admin"})
    assert reponse.status_code == 200
    assert reponse.json()["nom"] == "Chez nous"
    assert reponse.json()["modif_taches"] == "admin"
    assert reponse.json()["ajout_taches"] == "tous"


def test_un_reglage_inconnu_est_refuse(client, thomas):
    assert client.patch("/foyer", headers=thomas,
                        json={"ajout_taches": "personne"}).status_code == 422


def test_le_reglage_du_foyer_est_au_journal(client, thomas):
    client.patch("/foyer", headers=thomas, json={"ajout_taches": "admin"})
    lignes = _sql("SELECT libelle, apres ->> 'ajout_taches' FROM evenement WHERE objet = 'foyer'")
    assert ("Le foyer", "admin") in lignes


# ---------------------------------------------------------------------------
# Les droits sur les tâches                                             (FOY-6)
# ---------------------------------------------------------------------------

TACHE = {"code": "TEST_FOYER", "libelle": "Arroser", "categorie": "menage",
         "duree_minutes": 10, "periodicite_min_jours": 3, "periodicite_max_jours": 5}


def test_par_defaut_chacun_ajoute_et_modifie(client, lorette):
    creee = client.post("/taches", headers=lorette, json=TACHE)
    assert creee.status_code == 201, creee.text
    id_tache = creee.json()["id_tache"]
    assert creee.json()["ajoutee_par"] == _id("lorette")
    assert client.patch(f"/taches/{id_tache}", headers=lorette,
                        json={"duree_minutes": 15}).status_code == 200
    assert client.delete(f"/taches/{id_tache}", headers=lorette).status_code == 200


def test_l_admin_peut_reserver_la_modification(client, thomas, lorette):
    id_tache = client.post("/taches", headers=lorette, json=TACHE).json()["id_tache"]
    client.patch("/foyer", headers=thomas, json={"modif_taches": "admin"})

    assert client.patch(f"/taches/{id_tache}", headers=lorette,
                        json={"duree_minutes": 15}).status_code == 403
    assert client.delete(f"/taches/{id_tache}", headers=lorette).status_code == 403
    # L'ajout reste ouvert : les deux réglages sont séparés.
    assert client.post("/taches", headers=lorette,
                       json={**TACHE, "code": "TEST_FOYER_2"}).status_code == 201
    assert client.patch(f"/taches/{id_tache}", headers=thomas,
                        json={"duree_minutes": 15}).status_code == 200


# ---------------------------------------------------------------------------
# Les invitations                                                       (FOY-3)
# ---------------------------------------------------------------------------

def test_un_foyer_plein_n_invite_pas(client, thomas):
    reponse = client.post("/foyer/invitations", headers=thomas)
    assert reponse.status_code == 409
    assert "complet" in reponse.json()["message"]


def test_seul_l_admin_invite(client, thomas, lorette):
    assert client.post("/foyer/invitations", headers=lorette).status_code == 403


def test_une_invitation_cree_un_compte_dans_le_foyer(client, thomas, lorette):
    _liberer_une_place(client, thomas, lorette)
    code = _inviter(client, thomas)
    assert len(code) == 11 and code[5] == "-"
    # Le code n'est jamais stocké en clair.
    assert _sql("SELECT count(*) FROM invitation WHERE empreinte_code = %s",
                (hashlib.sha256(code.replace("-", "").encode()).hexdigest(),))[0][0] == 1
    assert client.get("/foyer", headers=thomas).json()["places_libres"] == 0

    # Tapé en minuscules et sans tiret, il marche quand même.
    compte = _rejoindre(client, code.replace("-", "").lower(), pseudo="Camille")
    assert compte.status_code == 201, compte.text
    assert compte.json()["pseudo"] == "camille"
    cle = {"X-Cle-Api": compte.json()["cle_api"]}
    assert len(compte.json()["cle_api"]) == 48

    foyer = client.get("/foyer", headers=cle).json()
    assert [m["pseudo"] for m in foyer["membres"]] == ["thomas", "camille"]
    assert foyer["je_suis_admin"] is False
    # Le mot de passe choisi ouvre ensuite la connexion normale.
    assert client.post("/connexion", json={"pseudo": "camille",
                                           "mot_de_passe": MOT_DE_PASSE}).status_code == 200


def test_un_code_ne_sert_qu_une_fois(client, thomas, lorette):
    _liberer_une_place(client, thomas, lorette)
    code = _inviter(client, thomas)
    assert _rejoindre(client, code).status_code == 201
    second = _rejoindre(client, code, pseudo="dominique")
    assert second.status_code == 409
    assert "plus valable" in second.json()["message"]


def test_un_code_inconnu_ou_expire_est_refuse(client, thomas, lorette):
    assert _rejoindre(client, "AAAAA-AAAAA").status_code == 409

    _liberer_une_place(client, thomas, lorette)
    code = _inviter(client, thomas)
    _sql("UPDATE invitation SET cree_le = now() - INTERVAL '3 days', "
         "expire_le = now() - INTERVAL '1 day'")
    assert _rejoindre(client, code).status_code == 409


def test_une_invitation_annulee_ne_sert_plus(client, thomas, lorette):
    _liberer_une_place(client, thomas, lorette)
    code = _inviter(client, thomas)
    invitations = client.get("/foyer", headers=thomas).json()["invitations"]
    assert len(invitations) == 1 and "code" not in invitations[0]

    assert client.delete(f"/foyer/invitations/{invitations[0]['id_invitation']}",
                         headers=thomas).status_code == 200
    assert _rejoindre(client, code).status_code == 409
    assert client.get("/foyer", headers=thomas).json()["places_libres"] == 1


@pytest.mark.parametrize("pseudo, mot_de_passe, statut", [
    ("thomas", MOT_DE_PASSE, 409),
    ("a b", MOT_DE_PASSE, 409),
    ("camille", "court", 422),
])
def test_le_pseudo_et_le_mot_de_passe_sont_controles(client, thomas, lorette,
                                                       pseudo, mot_de_passe, statut):
    _liberer_une_place(client, thomas, lorette)
    code = _inviter(client, thomas)
    assert _rejoindre(client, code, pseudo=pseudo, mot_de_passe=mot_de_passe).status_code == statut
    # Un refus ne consomme pas l'invitation.
    assert _rejoindre(client, code).status_code == 201


def test_accepter_une_invitation_ne_demande_pas_de_cle(client):
    reponse = _rejoindre(client, "BBBBB-BBBBB")
    assert reponse.json()["code"] != "cle_absente"


# ---------------------------------------------------------------------------
# Les membres                                                     (FOY-4, FOY-5)
# ---------------------------------------------------------------------------

def test_retirer_un_membre_rend_ses_taches_aux_autres(client, thomas, lorette):
    lorette_id = _id("lorette")
    plier = _sql("SELECT id_tache FROM tache WHERE code = 'PLIER_LINGE'")[0][0]
    assert _sql("SELECT id_utilisateur_defaut FROM tache WHERE id_tache = %s",
                (plier,))[0][0] == lorette_id

    assert client.delete(f"/foyer/membres/{lorette_id}", headers=lorette).status_code == 403
    reponse = client.delete(f"/foyer/membres/{lorette_id}", headers=thomas)
    assert reponse.status_code == 200
    assert [m["pseudo"] for m in reponse.json()["membres"]] == ["thomas"]
    assert reponse.json()["places_libres"] == 1

    assert _sql("SELECT id_utilisateur_defaut FROM tache WHERE id_tache = %s",
                (plier,))[0][0] is None
    assert _sql("""SELECT count(*) FROM occurrence o JOIN tache t USING (id_tache)
                    WHERE o.id_utilisateur = %s AND t.categorie <> 'sport'
                      AND o.statut IN ('a_placer', 'planifiee')""", (lorette_id,))[0][0] == 0
    # Le compte est mis en pause : sa clé ne répond plus.
    assert client.get("/foyer", headers=lorette).status_code == 401


def test_l_admin_ne_se_retire_pas_lui_meme(client, thomas):
    assert client.delete(f"/foyer/membres/{_id('thomas')}", headers=thomas).status_code == 409


def test_l_admin_passe_son_role_avant_de_partir(client, thomas, lorette):
    refus = client.post("/foyer/quitter", headers=thomas)
    assert refus.status_code == 409

    passe = client.post("/foyer/administrateur", headers=thomas,
                        json={"id_utilisateur": _id("lorette")})
    assert passe.status_code == 200
    assert passe.json()["je_suis_admin"] is False
    assert client.get("/foyer", headers=lorette).json()["je_suis_admin"] is True
    # L'administration du serveur ne bouge pas : c'est un autre rôle (FOY-11).
    assert _sql("SELECT role FROM utilisateur WHERE pseudo = 'thomas'")[0][0] == "admin"

    assert client.post("/foyer/quitter", headers=thomas).status_code == 200
    assert [m["pseudo"] for m in client.get("/foyer", headers=lorette).json()["membres"]] \
        == ["lorette"]


def test_le_dernier_qui_part_ferme_le_foyer(client, thomas, lorette):
    _liberer_une_place(client, thomas, lorette)
    _inviter(client, thomas)
    assert client.post("/foyer/quitter", headers=thomas).status_code == 200
    ferme, = _sql("SELECT ferme_le IS NOT NULL FROM foyer")[0]
    assert ferme
    # Ses invitations en cours tombent avec lui.
    assert _sql("SELECT count(*) FROM invitation WHERE annulee_le IS NULL")[0][0] == 0


# ---------------------------------------------------------------------------
# L'accès par internet                                                  (CNX-5)
# ---------------------------------------------------------------------------

def test_une_route_d_administration_ne_repond_pas_par_le_funnel(client, thomas):
    prive = client.post("/notifications/relance", headers=thomas)
    assert prive.status_code != 403

    par_internet = client.post("/notifications/relance",
                               headers={**thomas, "Tailscale-Funnel-Request": "?1"})
    assert par_internet.status_code == 403
    assert par_internet.json()["code"] == "reseau_prive"

    par_le_port = client.post("/notifications/relance",
                              headers={**thomas, "Host": "serveur.ts.net:8443"})
    assert par_le_port.status_code == 403


def test_le_refus_du_funnel_passe_avant_la_cle(client):
    # On vérifie la publication sans avoir à taper de clé sur le serveur.
    reponse = client.post("/notifications/relance", headers={"Tailscale-Funnel-Request": "?1"})
    assert reponse.status_code == 403
    assert reponse.json()["code"] == "reseau_prive"


@pytest.mark.parametrize("chemin", ["/planning/placer", "/sources/PERSO_THOMAS/collecter"])
def test_collecte_et_placement_restent_prives(client, thomas, chemin):
    reponse = client.post(chemin, headers={**thomas, "Tailscale-Funnel-Request": "?1"})
    assert reponse.status_code == 403


def test_une_route_de_l_appli_repond_par_le_funnel(client, thomas):
    reponse = client.get("/foyer", headers={**thomas, "Tailscale-Funnel-Request": "?1"})
    assert reponse.status_code == 200


# ---------------------------------------------------------------------------
# Les appareils                                                        (NOT-16)
# ---------------------------------------------------------------------------

JETON = "ab" * 32


def test_un_appareil_s_enregistre_une_fois(client, thomas, lorette):
    premier = client.post("/moi/appareils", headers=thomas,
                          json={"jeton": JETON, "nom": "iPhone", "environnement": "developpement"})
    assert premier.status_code == 200, premier.text
    client.post("/moi/appareils", headers=thomas, json={"jeton": JETON.upper()})
    assert _sql("SELECT count(*) FROM appareil")[0][0] == 1

    # Le même iPhone connecté à un autre compte le suit.
    client.post("/moi/appareils", headers=lorette, json={"jeton": JETON})
    assert _sql("SELECT id_utilisateur FROM appareil")[0][0] == _id("lorette")

    assert client.delete(f"/moi/appareils/{JETON}", headers=lorette).status_code == 200
    assert _sql("SELECT count(*) FROM appareil")[0][0] == 0


def test_un_jeton_mal_forme_est_refuse(client, thomas):
    assert client.post("/moi/appareils", headers=thomas,
                       json={"jeton": "pas-un-jeton"}).status_code == 422
