"""Ce que l'appli lit pour Aujourd'hui et Maison, et le mode allégé (lot 5)."""

from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import psycopg

from tests.conftest import _url

PARIS = ZoneInfo("Europe/Paris")
CATEGORIES = {"cours", "travail", "sport", "menage", "linge", "chat", "ia", "alerte", "perso"}


def sql(requete: str, *parametres):
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row, autocommit=True) as conn:
        curseur = conn.execute(requete, parametres or None)
        return curseur.fetchall() if curseur.description else []


def _id(pseudo: str) -> int:
    return sql("SELECT id_utilisateur FROM utilisateur WHERE pseudo = %s", pseudo)[0][
        "id_utilisateur"]


def heure(dans_heures: float) -> datetime:
    return datetime.now(PARIS) + timedelta(hours=dans_heures)


def test_tout_aujourdhui_en_un_appel(client, thomas):
    client.post("/planning/placer", headers=thomas)
    etat = client.get("/appli/aujourdhui", headers=thomas)
    assert etat.status_code == 200, etat.text
    corps = etat.json()

    assert [m["pseudo"] for m in corps["membres"]] == ["thomas", "lorette"]
    assert corps["membres"][0]["moi"] is True
    assert {"evenements", "taches", "conflit", "absences", "allegements", "chat",
            "equilibre", "propositions", "orbe", "droits"} <= corps.keys()
    assert corps["droits"] == {"ajouter": True, "modifier": True}
    assert len(corps["equilibre"]) == 2
    for tache in corps["taches"]:
        assert tache["categorie"] in CATEGORIES
        assert tache["categorie"] != "sport"
        assert tache["pour"] in (_id("thomas"), _id("lorette"))


def test_les_categories_parlent_la_langue_de_l_appli(client, thomas):
    client.post("/occupations", headers=thomas, json={
        "type": "cours", "libelle": "TD Analyse",
        "debut": heure(1).isoformat(), "fin": heure(2).isoformat(), "lieu": "Salle 112"})
    corps = client.get("/appli/aujourdhui", headers=thomas).json()
    cours = [e for e in corps["evenements"] if e["titre"] == "TD Analyse"]
    if heure(1).date() != heure(0).date():
        return
    assert cours and cours[0]["categorie"] == "cours"
    assert cours[0]["lieu"] == "Salle 112"
    assert all(e["categorie"] in CATEGORIES for e in corps["evenements"])


def test_une_tache_faite_aujourd_hui_reste_visible_cochee(client, thomas):
    client.post("/planning/placer", headers=thomas)
    corps = client.get("/appli/aujourdhui", headers=thomas).json()
    a_faire = [t for t in corps["taches"] if not t["faite"] and t["pour"] == _id("thomas")]
    if not a_faire:
        return
    client.post(f"/occurrences/{a_faire[0]['id']}/valider", headers=thomas)
    apres = client.get("/appli/aujourdhui", headers=thomas).json()
    faite = [t for t in apres["taches"] if t["id"] == a_faire[0]["id"]]
    assert faite and faite[0]["faite"] is True
    moi = next(e for e in apres["equilibre"] if e["pour"] == _id("thomas"))
    assert moi["minutes"] >= a_faire[0]["duree_minutes"]


def test_l_absence_de_l_autre_se_voit(client, thomas, lorette):
    client.post("/absences", headers=lorette, json={
        "debut": heure(24).isoformat(), "fin": heure(72).isoformat(), "lieu": "Lusse"})
    corps = client.get("/appli/aujourdhui", headers=thomas).json()
    assert [(a["pour"], a["lieu"]) for a in corps["absences"]] == [(_id("lorette"), "Lusse")]


def test_le_mode_allege_s_allume_et_s_eteint_dans_l_appli(client, thomas, lorette):
    assert client.get("/allegement", headers=thomas).json()["en_cours"] is False

    allume = client.put("/allegement", headers=thomas, json={"jours": 3})
    assert allume.status_code == 200, allume.text
    assert allume.json()["en_cours"] is True
    assert "mode allégé" in allume.json()["texte"]
    corps = client.get("/appli/aujourdhui", headers=lorette).json()
    assert [a["pour"] for a in corps["allegements"]] == [_id("thomas")]

    assert client.delete("/allegement", headers=thomas).json()["en_cours"] is False
    assert client.delete("/allegement", headers=thomas).status_code == 404


def test_une_duree_d_allegement_hors_bornes_est_refusee(client, thomas):
    assert client.put("/allegement", headers=thomas, json={"jours": 30}).status_code == 422


def test_l_appli_demande_le_replacement_dans_la_meme_requete(client, thomas):
    """CNX-5 : par le funnel, relancer le placement à part est refusé. L'appli le
    demande donc avec l'absence, le créneau ou la tâche qu'elle envoie."""
    par_internet = {**thomas, "Tailscale-Funnel-Request": "?1"}
    absence = client.post("/absences?replacer=true", headers=par_internet,
                          json={"debut": heure(24).isoformat(), "fin": heure(48).isoformat()})
    assert absence.status_code == 201, absence.text
    assert "occurrences_replacees" in absence.json()

    creneau = client.post("/occupations?replacer=true", headers=thomas, json={
        "type": "autre", "libelle": "Dentiste",
        "debut": heure(30).isoformat(), "fin": heure(31).isoformat()})
    assert "occurrences_replacees" in creneau.json()

    sans = client.post("/occupations", headers=thomas, json={
        "type": "autre", "libelle": "Garage",
        "debut": heure(50).isoformat(), "fin": heure(51).isoformat()})
    assert "occurrences_replacees" not in sans.json()

    supprimee = client.delete(f"/absences/{absence.json()['id_absence']}?replacer=true",
                              headers=thomas)
    assert supprimee.status_code == 204


# ---------------------------------------------------------------------------
# L'onglet Sport et la séance hors réseau                              (lot 6)
# ---------------------------------------------------------------------------

def test_l_onglet_sport_en_un_appel(client, thomas):
    corps = client.get("/appli/sport", headers=thomas)
    assert corps.status_code == 200, corps.text
    sport = corps.json()
    assert {"coach_actif", "semaine", "seances_du_jour", "forme", "objectif", "mesures",
            "ajustements", "pause"} <= sport.keys()
    assert {"faites", "prevues", "prochaine"} <= sport["semaine"].keys()


def test_une_seance_libre_hors_reseau_arrive_sans_doublon(client, thomas):
    """SAI-9, SAI-10 : l'appli ouvre la séance avec sa clé, puis envoie séries et
    bilan sur cette clé. Tout renvoyer deux fois ne crée rien de plus."""
    import uuid

    sql("UPDATE utilisateur SET coach_actif = TRUE WHERE pseudo = 'thomas'")
    cle = str(uuid.uuid4())
    serie = {"code": "presse_pectoraux", "cle_client": str(uuid.uuid4()),
             "charge_kg": 40, "repetitions": 10, "saisie_le": heure(-1).isoformat()}
    bilan = {"effort": 7, "duree_minutes": 45, "cle_client": str(uuid.uuid4())}

    for _ in range(2):
        ouverte = client.post("/seances/libre", headers=thomas, json={
            "discipline": "musculation", "cle_client": cle, "debut": heure(-1.5).isoformat()})
        assert ouverte.status_code == 201, ouverte.text
        envoi = client.post(f"/seances/par-cle/{cle}/series", headers=thomas, json=[serie])
        assert envoi.status_code == 200, envoi.text
        assert envoi.json()["series"][0]["etat"] in ("creee", "existait")
        close = client.post(f"/seances/par-cle/{cle}/bilan", headers=thomas, json=bilan)
        assert close.status_code == 200, close.text

    occurrences = sql("SELECT count(*) AS n FROM seance WHERE cle_client = %s", cle)
    assert occurrences[0]["n"] == 1
    series = sql("SELECT count(*) AS n FROM serie_saisie WHERE cle_client = %s",
                 serie["cle_client"])
    assert series[0]["n"] == 1
    assert close.json()["seance"]["seance"]["situation"] == "faite"


def test_une_cle_inconnue_est_refusee(client, thomas):
    import uuid

    reponse = client.post(f"/seances/par-cle/{uuid.uuid4()}/series", headers=thomas, json=[])
    assert reponse.status_code == 404


def test_une_mesure_de_test_de_course_se_note_au_temps(client, thomas):
    sql("INSERT INTO fenetre_mesure (id_utilisateur, type_mesure, periode, consigne) "
        "SELECT id_utilisateur, 'test_course', daterange(CURRENT_DATE, CURRENT_DATE + 5), "
        "'3 km' FROM utilisateur WHERE pseudo = 'thomas'")
    reponse = client.post("/mesures", headers=thomas,
                          json={"type": "test_course", "valeur": 780, "unite": "s"})
    assert reponse.status_code == 201, reponse.text
    assert sql("SELECT statut FROM fenetre_mesure")[0]["statut"] == "faite"
    # MES-2 : la date de Paris, jamais refusée comme une date du futur.
    assert sql("SELECT date_mesure = (now() AT TIME ZONE 'Europe/Paris')::DATE AS ok "
               "FROM mesure")[0]["ok"]


def test_la_semaine_la_sante_et_la_progression(client, thomas):
    import uuid

    sql("UPDATE utilisateur SET coach_actif = TRUE WHERE pseudo = 'thomas'")
    cle = str(uuid.uuid4())
    client.post("/seances/libre", headers=thomas, json={"discipline": "musculation",
                                                       "cle_client": cle})
    client.post(f"/seances/par-cle/{cle}/series", headers=thomas, json=[{
        "code": "presse_pectoraux", "cle_client": str(uuid.uuid4()),
        "charge_kg": 40, "repetitions": 10}])
    client.put("/donnees-sante/jours/" + heure(0).date().isoformat(), headers=thomas,
               json={"pas": 8000, "sommeil_minutes": 450})

    semaine = client.get("/appli/semaine", headers=thomas).json()
    assert {"lundi", "a_valider", "seances", "role"} <= semaine.keys()
    assert any(s["discipline"] == "musculation" for s in semaine["seances"])

    sante = client.get("/appli/sante?jours=7", headers=thomas).json()
    assert sante["jours"][-1]["sommeil_minutes"] == 450

    progression = client.get("/appli/progression", headers=thomas).json()
    assert progression[0]["code"] == "presse_pectoraux"
    assert progression[0]["meilleure_charge"] == 40

    sport = client.get("/appli/sport", headers=thomas).json()
    assert "semaine_a_valider" in sport and sport["invitations"] == []


def test_une_invitation_inconnue_est_refusee(client, lorette):
    reponse = client.post("/seances/invitations/999/repondre", headers=lorette,
                          json={"vient": True})
    assert reponse.status_code == 404


def test_une_fenetre_de_mesure_attend_son_premier_jour(client, thomas):
    """MES-1 : HAL ouvre une fenêtre pour plus tard ; elle ne se montre qu'à son début."""
    sql("INSERT INTO fenetre_mesure (id_utilisateur, type_mesure, periode, consigne) "
        "SELECT id_utilisateur, 'test_course', daterange(jour_de(now()) + 3, jour_de(now()) + 5), "
        "'3 km' FROM utilisateur WHERE pseudo = 'thomas'")
    sql("INSERT INTO fenetre_mesure (id_utilisateur, type_mesure, periode, consigne) "
        "SELECT id_utilisateur, 'poids', daterange(jour_de(now()), jour_de(now()) + 2), "
        "'à jeun' FROM utilisateur WHERE pseudo = 'thomas'")
    sport = client.get("/appli/sport", headers=thomas).json()
    assert [m["type_mesure"] for m in sport["mesures"]] == ["poids"]


def test_l_historique_des_mesures_et_la_charge(client, thomas):
    sql("UPDATE utilisateur SET coach_actif = TRUE WHERE pseudo = 'thomas'")
    for valeur in (71.2, 70.8):
        saisie = client.post("/mesures", headers=thomas,
                             json={"type": "poids", "valeur": valeur, "unite": "kg"})
        assert saisie.status_code == 201
    client.post("/mesures", headers=thomas,
                json={"type": "tour_taille", "valeur": 80, "unite": "cm"})
    poids = client.get("/appli/mesures?type=poids", headers=thomas).json()
    assert [m["valeur"] for m in poids] == [70.8, 71.2]
    assert len(client.get("/appli/mesures", headers=thomas).json()) == 3
    semaine = client.get("/appli/semaine", headers=thomas).json()
    assert "charge" in semaine


def test_une_seance_libre_lancee_par_erreur_s_annule(client, thomas):
    """SAI-19 : elle disparaît avec ses séries ; une seconde annulation ne trouve rien."""
    import uuid

    sql("UPDATE utilisateur SET coach_actif = TRUE WHERE pseudo = 'thomas'")
    cle = str(uuid.uuid4())
    client.post("/seances/libre", headers=thomas, json={"discipline": "musculation",
                                                       "cle_client": cle})
    client.post(f"/seances/par-cle/{cle}/series", headers=thomas, json=[{
        "code": "presse_pectoraux", "cle_client": str(uuid.uuid4()),
        "charge_kg": 40, "repetitions": 10}])
    annule = client.delete(f"/seances/par-cle/{cle}", headers=thomas)
    assert annule.status_code == 200, annule.text
    assert sql("SELECT count(*) AS n FROM seance WHERE cle_client = %s", cle)[0]["n"] == 0
    assert sql("SELECT count(*) AS n FROM serie_saisie")[0]["n"] == 0
    assert client.delete(f"/seances/par-cle/{cle}", headers=thomas).status_code == 404


def test_une_seance_libre_avec_bilan_ne_s_annule_plus(client, thomas):
    import uuid

    sql("UPDATE utilisateur SET coach_actif = TRUE WHERE pseudo = 'thomas'")
    cle = str(uuid.uuid4())
    client.post("/seances/libre", headers=thomas, json={"discipline": "musculation",
                                                       "cle_client": cle})
    client.post(f"/seances/par-cle/{cle}/bilan", headers=thomas,
                json={"effort": 6, "duree_minutes": 30, "cle_client": str(uuid.uuid4())})
    assert client.delete(f"/seances/par-cle/{cle}", headers=thomas).status_code == 409


def test_annuler_un_lancement_ne_retire_que_ses_series(client, thomas):
    import uuid

    sql("UPDATE utilisateur SET coach_actif = TRUE WHERE pseudo = 'thomas'")
    cle = str(uuid.uuid4())
    client.post("/seances/libre", headers=thomas, json={
        "discipline": "musculation", "cle_client": cle})
    id_occurrence = sql("SELECT id_occurrence FROM seance WHERE cle_client = %s",
                        cle)[0]["id_occurrence"]
    avant, pendant = str(uuid.uuid4()), str(uuid.uuid4())
    for numero, cle_serie in ((1, avant), (2, pendant)):
        client.post(f"/seances/par-cle/{cle}/series", headers=thomas, json=[{
            "code": "presse_pectoraux", "cle_client": cle_serie, "numero": numero,
            "charge_kg": 40, "repetitions": 10}])
    rendu = client.post(f"/seances/{id_occurrence}/annuler-saisie", headers=thomas,
                        json={"cles": [pendant]})
    assert rendu.status_code == 200, rendu.text
    assert rendu.json()["retirees"] == 1
    assert [s["cle_client"] for s in sql("SELECT cle_client::TEXT FROM serie_saisie")] == [avant]


def test_une_seance_libre_oubliee_s_annule_par_son_numero(client, thomas):
    import uuid

    sql("UPDATE utilisateur SET coach_actif = TRUE WHERE pseudo = 'thomas'")
    cle = str(uuid.uuid4())
    client.post("/seances/libre", headers=thomas, json={"discipline": "musculation",
                                                       "cle_client": cle})
    numero = sql("SELECT id_occurrence FROM seance WHERE cle_client = %s",
                 cle)[0]["id_occurrence"]
    assert client.delete(f"/seances/{numero}/libre", headers=thomas).status_code == 200
    assert client.delete(f"/seances/{numero}/libre", headers=thomas).status_code == 404
