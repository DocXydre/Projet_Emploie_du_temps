# ruff: noqa: F811 - les fixtures du coach sont reprises telles quelles
"""HAL dans l'appli : le moment « changement », l'écran affiché, le démarrage (lot 7)."""

import json
import uuid

from api.coach import outils
from tests.test_coach import dit, faux, lieu, plan, proposer, u  # noqa: F401
from tests.test_ensemble import _id, sql, un


def noms(moment: str, en_pause: bool = False) -> set[str]:
    return {o.nom for o in outils.outils_du_moment(moment, en_pause)}


def test_le_moment_changement_propose_sans_rien_construire():
    permis = noms("changement")
    assert {"modifier_seance_proposee", "retirer_seance_proposee", "proposer_ajustement",
            "lire_semaine", "ecrire_memoire"} <= permis
    assert "ecrire_trame" not in permis and "requalifier_en_signalement" not in permis
    assert "proposer_ajustement" not in noms("changement", en_pause=True)


def test_un_changement_sur_une_seance_joint_la_seance_et_l_ecran(client, thomas, u, faux, plan):
    seance = proposer(u, 3)
    joue = faux(dit("Je te propose de la passer à jeudi."))
    rendu = client.post("/coach/changement", headers=thomas, json={
        "texte": "Je ne peux pas ce jour-là", "id_occurrence": seance,
        "cle_client": str(uuid.uuid4()), "ecran": "Sport, la séance prévue"})
    assert rendu.status_code == 200, rendu.text
    assert rendu.json()["moment"] == "changement"
    envoye = json.dumps(joue.appels[0]["messages"], ensure_ascii=False)
    assert f"id_occurrence {seance}" in envoye
    assert "L'appli affiche : Sport, la séance prévue" in envoye
    assert "proposer_ajustement" in joue.appels[0]["outils"]
    assert sql("SELECT moment, importance FROM echange WHERE auteur = 'utilisateur'") == [
        {"moment": "changement", "importance": 2}]


def test_un_changement_sur_une_seance_d_un_autre_est_refuse(client, u, plan, lorette):
    seance = proposer(u, 3)
    rendu = client.post("/coach/changement", headers=lorette, json={
        "texte": "Non", "id_occurrence": seance, "cle_client": str(uuid.uuid4())})
    assert rendu.status_code in (403, 404)


def test_la_question_porte_l_ecran(client, thomas, u, faux):
    joue = faux(dit("Bonne question."))
    # AIG-2 : depuis l'onglet Sport, le message va au HAL sport.
    client.post("/coach/question", headers=thomas, json={
        "texte": "Et demain ?", "cle_client": str(uuid.uuid4()), "ecran": "Sport"})
    envoye = json.dumps(joue.appels[0]["messages"], ensure_ascii=False)
    assert "L'appli affiche : Sport" in envoye


def test_le_demarrage_dans_l_appli(client, thomas, faux):
    etat = client.get("/appli/demarrage", headers=thomas).json()
    assert etat["manque"] == "profil" and etat["coach_actif"] is False
    assert etat["lieux_possibles"]

    # DEM-2 : le brouillon est gardé, sans rien créer.
    client.put("/appli/demarrage/brouillon", headers=thomas,
               json={"etape": "profil_niveaux", "reponses": {"sexe": "homme"}})
    etat = client.get("/appli/demarrage", headers=thomas).json()
    assert etat["etape"] == "profil_niveaux" and etat["brouillon"] == {"sexe": "homme"}
    assert etat["profil"] is None

    # Activer sans profil : la base refuse (COA-1, PRO-7).
    assert client.post("/appli/demarrage/activer", headers=thomas).status_code >= 400
    client.put("/profil", headers=thomas, json={
        "date_naissance": "2000-01-01", "sexe": "homme", "taille_cm": 180,
        "niveau_musculation": "intermediaire", "niveau_course": "debutant"})
    active = client.post("/appli/demarrage/activer", headers=thomas)
    assert active.status_code == 200, active.text
    assert client.get("/appli/demarrage", headers=thomas).json()["manque"] == "limitations"

    client.post("/appli/demarrage/limitations-faites", headers=thomas)
    etat = client.get("/appli/demarrage", headers=thomas).json()
    assert etat["manque"] == "lieux" and etat["limitations_faites"]
    # Le brouillon de l'appli survit à ce que le démarrage garde à côté.
    assert etat["brouillon"] == {"sexe": "homme"}

    client.put("/disciplines/musculation/lieux", headers=thomas, json=[lieu("SALLE")])
    assert client.get("/appli/demarrage", headers=thomas).json()["manque"] == "objectif"
    assert client.get("/appli/sport", headers=thomas).json()["demarrage"] == "objectif"


def test_le_maximum_de_seances(client, thomas):
    reponse = client.put("/appli/seances-max", headers=thomas, json={"valeur": 4})
    assert reponse.status_code == 200
    assert un("SELECT seances_max_semaine FROM utilisateur WHERE id_utilisateur = %s",
              _id("thomas")) == 4
    trop = client.put("/appli/seances-max", headers=thomas, json={"valeur": 20})
    assert trop.status_code == 422
    client.put("/appli/seances-max", headers=thomas, json={"valeur": None})
    assert sql("SELECT seances_max_semaine FROM utilisateur WHERE pseudo = 'thomas'")[0][
        "seances_max_semaine"] is None


def test_un_echange_relu_dit_si_ses_boutons_servent_encore(client, thomas, u, faux, plan):
    from tests.test_coach import demande

    seance = proposer(u, 3)
    sql("UPDATE seance SET etat = 'validee' WHERE id_occurrence = %s", seance)
    faux(demande(("proposer_ajustement", {"id_occurrence": seance, "nature": "alleger",
                                          "contenu": {"duree_minutes": 30},
                                          "motif": "fatigue"})),
         dit("Je te propose de l'alléger."))
    rendu = client.post("/coach/signalement", headers=thomas, json={
        "texte": "Je suis fatigué", "cle_client": str(uuid.uuid4())}).json()
    ajustement = next(e for e in rendu["elements"] if e["type"] == "ajustement")

    def etat():
        lus = client.get("/coach/echanges", headers=thomas).json()
        return next(e["etat"] for m in lus for e in m["elements"] if e["type"] == "ajustement")

    assert etat() == "en_attente"
    client.post(f"/ajustements/{ajustement['id_ajustement']}/accepter", headers=thomas)
    assert etat() == "accepte"


def test_une_seance_proposee_a_son_bouton_valider():
    from api.coach import reponse

    noms = [a["libelle"] for a in reponse.actions({"type": "seance_proposee", "id_occurrence": 1})]
    assert noms[0] == "Valider"
