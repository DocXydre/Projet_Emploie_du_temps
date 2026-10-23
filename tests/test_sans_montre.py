"""Le sport sans montre : l'interrupteur, l'effort d'une course reçue d'une autre
appli, la course déclarée à la main (MON-7 à MON-15, migration 074)."""

# ruff: noqa: F811 (les fixtures de test_coach sont importées puis demandées)

import uuid
from datetime import datetime, timedelta

from api.coach import contexte
from tests.test_coach import u  # noqa: F401
from tests.test_ensemble import PARIS, sql, un


def _debut(heures=3) -> datetime:
    return datetime.now(PARIS).replace(microsecond=0) - timedelta(hours=heures)


def _recue(client, entete, *, debut, minutes=40, source="Strava", appareil=None) -> dict:
    details = {"source": source, **({"appareil": appareil} if appareil else {})}
    rendu = client.put(f"/donnees-sante/activites/{uuid.uuid4()}", headers=entete, json={
        "type": "running", "debut": debut.isoformat(),
        "fin": (debut + timedelta(minutes=minutes)).isoformat(),
        "distance_m": 5200, "details": details})
    assert rendu.status_code == 200, rendu.text
    return rendu.json()


def _efforts(client, entete) -> list[dict]:
    return client.get("/appli/sport", headers=entete).json()["efforts_a_donner"]


def _a_la_main(client, entete, **champs):
    corps = {"cle_client": str(uuid.uuid4()), "debut": _debut(2).isoformat(),
             "duree_minutes": 35, "effort": 5, **champs}
    return client.post("/seances/course-a-la-main", headers=entete, json=corps)


# --- MON-7, MON-15 : l'interrupteur ------------------------------------------------

def test_la_montre_se_regle_a_la_main_et_hal_le_lit(client, thomas, u):
    assert client.get("/appli/sport", headers=thomas).json()["a_une_montre"] is True
    assert "Apple Watch : oui" in contexte.texte(u)

    rendu = client.put("/appli/montre", headers=thomas, json={"valeur": False})
    assert rendu.status_code == 200, rendu.text
    assert client.get("/appli/sport", headers=thomas).json()["a_une_montre"] is False
    texte = contexte.texte(u)
    assert "Apple Watch : non" in texte and "effort perçu" in texte


def test_la_montre_de_l_un_ne_change_pas_celle_de_l_autre(client, thomas, lorette):
    client.put("/appli/montre", headers=thomas, json={"valeur": False})
    assert client.get("/appli/sport", headers=lorette).json()["a_une_montre"] is True


# --- MON-11 : l'effort d'une course reçue sans la montre ---------------------------

def test_une_course_de_strava_demande_son_effort(client, thomas, u):
    recue = _recue(client, thomas, debut=_debut(2))
    seance = recue["id_occurrence"]
    assert seance is not None
    assert [e["id_occurrence"] for e in _efforts(client, thomas)] == [seance]
    notes = sql("SELECT contenu FROM notification WHERE id_occurrence = %s AND type = 'sport'",
                seance)
    assert len(notes) == 1
    assert "Course de 5,2 km reçue de Strava : quel effort" in notes[0]["contenu"]

    # La note, sans durée : celle de la course reçue.
    rendu = client.post(f"/seances/{seance}/bilan", headers=thomas, json={"effort": 3})
    assert rendu.status_code == 200, rendu.text
    assert un("SELECT duree_minutes FROM bilan_seance WHERE id_occurrence = %s", seance) == 40
    # Séance libre : l'intensité vient maintenant de la note (LIB-12).
    assert un("SELECT intensite FROM seance WHERE id_occurrence = %s", seance) == "legere"
    assert _efforts(client, thomas) == []


def test_une_course_de_la_montre_ne_demande_rien(client, thomas, u):
    _recue(client, thomas, debut=_debut(2), source="Apple Watch de Thomas", appareil="Watch")
    assert _efforts(client, thomas) == []
    assert un("SELECT count(*) FROM notification WHERE type = 'sport'") == 0


def test_l_effort_n_est_demande_qu_une_fois(client, thomas, u):
    debut = _debut(2)
    cle = str(uuid.uuid4())
    corps = {"type": "running", "debut": debut.isoformat(),
             "fin": (debut + timedelta(minutes=40)).isoformat(), "details": {"source": "Strava"}}
    client.put(f"/donnees-sante/activites/{cle}", headers=thomas, json=corps)
    client.put(f"/donnees-sante/activites/{cle}", headers=thomas, json=corps)
    assert un("SELECT count(*) FROM notification WHERE type = 'sport'") == 1


def test_l_historique_ne_reveille_personne(client, thomas, u):
    # Deux jours : la carte l'attend encore, la notification ne part pas.
    _recue(client, thomas, debut=_debut(48))
    assert len(_efforts(client, thomas)) == 1
    assert un("SELECT count(*) FROM notification WHERE type = 'sport'") == 0
    # Quatre jours : trop tard, la séance reste sans charge (SAI-13).
    sql("UPDATE activite_sante SET periode = tstzrange(lower(periode) - INTERVAL '2 days', "
        "upper(periode) - INTERVAL '2 days')")
    assert _efforts(client, thomas) == []


# --- MON-12, MON-13 : la course déclarée à la main ---------------------------------

def test_une_course_se_declare_a_la_main(client, thomas, u):
    cle = str(uuid.uuid4())
    rendu = _a_la_main(client, thomas, cle_client=cle, distance_m=6000, effort=8,
                       terrain="foret", commentaire="Boueux")
    assert rendu.status_code == 201, rendu.text
    corps = rendu.json()
    seance = corps["id_occurrence"]
    assert corps["etat"] == "cree"
    assert corps["seance"]["seance"]["situation"] == "faite"
    activite = sql("SELECT type, discipline, allure_s_km, details FROM activite_sante")[0]
    assert activite["type"] == "running" and activite["discipline"] == "course"
    assert activite["allure_s_km"] == 350
    assert activite["details"]["saisie_manuelle"] is True
    assert activite["details"]["terrain"] == "foret"
    assert un("SELECT effort FROM bilan_seance WHERE id_occurrence = %s", seance) == 8
    assert un("SELECT intensite FROM seance WHERE id_occurrence = %s", seance) == "dure"
    # Elle porte son effort : rien à demander de plus.
    assert _efforts(client, thomas) == []

    # Renvoyée après une coupure : rien de plus.
    assert _a_la_main(client, thomas, cle_client=cle, distance_m=6000, effort=8,
                      terrain="foret").json()["id_occurrence"] == seance
    assert un("SELECT count(*) FROM activite_sante") == 1
    assert un("SELECT count(*) FROM bilan_seance") == 1


def test_strava_passe_devant_la_saisie_a_la_main(client, thomas, u):
    debut = _debut(2)
    main = _a_la_main(client, thomas, debut=debut.isoformat(), duree_minutes=40, effort=6)
    seance = main.json()["id_occurrence"]

    recue = _recue(client, thomas, debut=debut + timedelta(minutes=1), minutes=39)
    assert recue["id_occurrence"] == seance
    lignes = {ligne["source"]: ligne for ligne in sql(
        "SELECT details ->> 'source' AS source, id_activite, doublon_de, id_occurrence "
        "FROM activite_sante")}
    assert lignes["Saisie à la main"]["doublon_de"] == lignes["Strava"]["id_activite"]
    assert lignes["Strava"]["id_occurrence"] == seance
    # Le bilan reste, et Strava ne redemande pas l'effort.
    assert un("SELECT effort FROM bilan_seance WHERE id_occurrence = %s", seance) == 6
    assert un("SELECT count(*) FROM notification WHERE type = 'sport'") == 0


def test_une_course_deja_recue_prend_l_effort_declare(client, thomas, u):
    debut = _debut(2)
    seance = _recue(client, thomas, debut=debut)["id_occurrence"]
    rendu = _a_la_main(client, thomas, debut=debut.isoformat(), duree_minutes=40, effort=4)
    assert rendu.status_code == 201, rendu.text
    assert rendu.json()["id_occurrence"] == seance
    assert un("SELECT effort FROM bilan_seance WHERE id_occurrence = %s", seance) == 4


def test_une_course_a_la_main_remplit_la_course_prevue(client, thomas, u):
    debut = _debut(3)
    prevue = un("SELECT creer_seance_libre(%s, 'course', %s, 45, NULL, TRUE)", u, debut)
    rendu = _a_la_main(client, thomas, debut=(debut + timedelta(minutes=10)).isoformat(),
                       effort=5)
    assert rendu.json()["id_occurrence"] == prevue


def test_une_course_a_la_main_a_des_limites(client, thomas, lorette, u):
    futur = (datetime.now(PARIS) + timedelta(hours=1)).isoformat()
    assert _a_la_main(client, thomas, debut=futur).status_code == 422
    vieille = (datetime.now(PARIS) - timedelta(days=40)).isoformat()
    assert _a_la_main(client, thomas, debut=vieille).status_code == 422
    assert _a_la_main(client, thomas, effort=11).status_code == 422
    assert _a_la_main(client, thomas, terrain="plage").status_code == 422
    # Sans HAL, elle n'a pas de séance où se ranger.
    refus = _a_la_main(client, lorette)
    assert refus.status_code == 403, refus.text
    assert refus.json()["code"] == "coach_inactif"
    assert un("SELECT count(*) FROM activite_sante") == 0


# --- Cette semaine : chaque séance a sa propre activité -----------------------------

def test_deux_courses_du_meme_jour_gardent_chacune_leur_seance(client, thomas, u):
    matin = _recue(client, thomas, debut=_debut(9), minutes=30)
    client.put(f"/donnees-sante/activites/{uuid.uuid4()}", headers=thomas, json={
        "type": "running", "debut": _debut(4).isoformat(),
        "fin": (_debut(4) + timedelta(minutes=45)).isoformat(),
        "distance_m": 8100, "details": {"source": "Strava"}})
    seances = client.get("/appli/sante?jours=7", headers=thomas).json()["seances"]
    assert len(seances) == 2
    par_seance = {s["id_occurrence"]: s["distance_m"] for s in seances}
    assert None not in par_seance and len(par_seance) == 2
    assert par_seance[matin["id_occurrence"]] == 5200
    assert sorted(par_seance.values()) == [5200, 8100]
