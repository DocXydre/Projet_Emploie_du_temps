"""Parcours de l'API contre un vrai PostgreSQL."""

from datetime import UTC, datetime, timedelta

from icalendar import Calendar

from tests.conftest import JETON_THOMAS, id_de


def demain(heure: int, minute: int = 0) -> datetime:
    base = datetime.now(UTC) + timedelta(days=1)
    return base.replace(hour=heure, minute=minute, second=0, microsecond=0)


# ---------------------------------------------------------------------------
# Authentification
# ---------------------------------------------------------------------------

def test_sante_ne_demande_pas_de_cle(client):
    reponse = client.get("/sante")
    assert reponse.status_code == 200
    assert reponse.json()["base"] == "ok"


def test_sans_cle_on_est_refuse(client):
    assert client.get("/taches").status_code == 401


def test_cle_inconnue_refusee(client):
    assert client.get("/taches", headers={"X-Cle-Api": "X" * 48}).status_code == 401


def test_moi_renvoie_le_bon_profil(client, lorette):
    profil = client.get("/moi", headers=lorette).json()
    assert profil["pseudo"] == "lorette"
    assert profil["role"] == "standard"


# ---------------------------------------------------------------------------
# Tâches de référence
# ---------------------------------------------------------------------------

def test_les_taches_de_reference_sont_la(client, thomas):
    taches = client.get("/taches", headers=thomas).json()
    ids = {t["id_tache"] for t in taches}

    assert {id_de(c) for c in ("ASPIRATEUR", "POUSSIERE", "LITIERE_CROTTES", "LESSIVE_BLANC",
                               "GRAND_NETTOYAGE")} <= ids
    # Retirée avec le stock d'uniforme : elle ne sert plus à rien.
    assert id_de("LESSIVE_TRAVAIL") not in ids

    poussiere = next(t for t in taches if t["id_tache"] == id_de("POUSSIERE"))
    assert poussiere["duree_minutes"] == 5
    assert poussiere["rappel_journee"] is True
    # Lancer le lave-vaisselle déclenche son vidage, le lendemain (TAC-14).
    lancer = next(t for t in taches if t["id_tache"] == id_de("LAVE_VAISSELLE"))
    assert any(d["id_tache_suivante"] == id_de("VIDER_LAVE_VAISSELLE") for d in lancer["declenche"])
    # L'aspirateur, lui, ne suit plus la poussière après coup : il est prévu le
    # même jour, dès le planning (TAC-15).
    assert not poussiere["declenche"]

    lessive = next(t for t in taches if t["id_tache"] == id_de("LESSIVE_BLANC"))
    assert lessive["rappel_journee"] is False

    # TAC-29 : ce qu'elle avait de plus est dans sa description.
    litiere = next(t for t in taches if t["id_tache"] == id_de("LITIERE_CROTTES"))
    assert "Ne se décale pas" in litiere["description"]["texte"]


def test_le_pliage_revient_a_lorette(client, thomas):
    taches = client.get("/taches", headers=thomas).json()
    plier = next(t for t in taches if t["id_tache"] == id_de("PLIER_LINGE"))
    profil = client.get("/moi", headers={"X-Cle-Api": "L" * 48}).json()
    assert plier["id_utilisateur_defaut"] == profil["id_utilisateur"]


def test_l_admin_du_foyer_peut_garder_les_taches(client, thomas, lorette):
    # FOY-6 : tout le monde ajoute par défaut ; l'administrateur peut le réserver.
    assert client.patch("/foyer", headers=thomas,
                        json={"ajout_taches": "admin"}).status_code == 200
    reponse = client.post("/taches/nouvelle", headers=lorette, json={
        "libelle": "Interdit", "duree_minutes": 10, "tous_les_jours": 1,
    })
    assert reponse.status_code == 403


# ---------------------------------------------------------------------------
# Occupations
# ---------------------------------------------------------------------------

def test_saisie_manuelle_puis_lecture(client, thomas):
    creation = client.post("/occupations", headers=thomas, json={
        "type": "travail", "libelle": "Shift McDonald's",
        "debut": demain(17).isoformat(), "fin": demain(23).isoformat(),
        "lieu": "Nancy",
    })
    assert creation.status_code == 201

    occupations = client.get("/occupations", headers=thomas).json()
    assert any(o["libelle"] == "Shift McDonald's" for o in occupations)


def test_deux_shifts_qui_se_chevauchent_sont_refuses(client, thomas):
    corps = {
        "type": "travail", "libelle": "Shift",
        "debut": demain(17).isoformat(), "fin": demain(23).isoformat(),
    }
    assert client.post("/occupations", headers=thomas, json=corps).status_code == 201

    doublon = client.post("/occupations", headers=thomas, json={
        **corps, "libelle": "Shift en double",
        "debut": demain(18).isoformat(), "fin": demain(20).isoformat(),
    })
    # C'est la contrainte d'exclusion de la base qui refuse, pas du code Python.
    assert doublon.status_code == 409
    assert doublon.json()["code"] == "chevauchement"


# ---------------------------------------------------------------------------
# Placement et validation
# ---------------------------------------------------------------------------

def test_placement_puis_validation_et_recurrence(client, thomas):
    place = client.post("/planning/placer", headers=thomas).json()
    assert place["placees"] > 0

    occurrences = client.get("/occurrences", headers=thomas,
                             params={"statut": ["planifiee"]}).json()
    poussiere = next(o for o in occurrences if o["id_tache"] == id_de("POUSSIERE"))

    # Les rappels sortent sur une journée entière.
    assert poussiere["rappel_journee"] is True
    assert "faite" in poussiere["actions_possibles"]

    validee = client.post(f"/occurrences/{poussiere['id_occurrence']}/valider",
                          headers=thomas, json={}).json()
    assert validee["statut"] == "faite"
    assert validee["date_faite"] is not None
    reelle = datetime.fromisoformat(validee["date_faite"])

    toutes = client.get("/occurrences", headers=thomas).json()

    # EXE-1 : la suivante repart de la date réelle.
    suivante = next(o for o in toutes
                    if o["id_tache"] == id_de("POUSSIERE") and o["statut"] != "faite")
    debut_suivante = datetime.fromisoformat(suivante["echeance_min"])
    assert debut_suivante > datetime.now(UTC) + timedelta(days=6)

    # L'enchaînement vers l'aspirateur (EXE-2) se vérifie au niveau SQL, dans
    # test_placement : depuis EXE-15 le planning se refait aussitôt, et le
    # placement efface le motif « Repositionnée » en posant le créneau.
    assert reelle <= datetime.now(UTC)


def test_revalider_est_refuse(client, thomas):
    client.post("/planning/placer", headers=thomas)
    occurrence = client.get("/occurrences", headers=thomas).json()[0]
    identifiant = occurrence["id_occurrence"]

    assert client.post(f"/occurrences/{identifiant}/valider", headers=thomas,
                       json={}).status_code == 200

    seconde = client.post(f"/occurrences/{identifiant}/valider", headers=thomas, json={})
    assert seconde.status_code == 409
    assert "close" in seconde.json()["message"]


def test_valider_dans_le_futur_est_refuse(client, thomas):
    client.post("/planning/placer", headers=thomas)
    occurrence = client.get("/occurrences", headers=thomas).json()[0]

    reponse = client.post(
        f"/occurrences/{occurrence['id_occurrence']}/valider",
        headers=thomas,
        json={"date_reelle": (datetime.now(UTC) + timedelta(days=1)).isoformat()},
    )
    assert reponse.status_code == 409
    assert "futur" in reponse.json()["message"]


def test_lorette_valide_une_tache_de_thomas_et_se_la_voit_crediter(
        client, thomas, lorette):
    """EXE-14 : la vaisselle est faite par qui passe devant.

    Refuser cette validation, comme avant, obligeait à laisser au planning une
    tâche déjà faite, ou à la faire cocher par l'autre.
    """
    client.post("/planning/placer", headers=thomas)
    occurrences = client.get("/occurrences", headers=thomas).json()
    a_thomas = next(o for o in occurrences if o["assigne_a"] == "thomas")

    reponse = client.post(f"/occurrences/{a_thomas['id_occurrence']}/valider",
                          headers=lorette, json={})

    assert reponse.status_code == 200
    apres = client.get(f"/occurrences/{a_thomas['id_occurrence']}",
                       headers=thomas).json()
    assert apres["statut"] == "faite"
    assert apres["assigne_a"] == "lorette"


def test_reporter_remet_la_tache_a_placer(client, thomas):
    client.post("/planning/placer", headers=thomas)
    occurrences = client.get("/occurrences", headers=thomas).json()
    aspirateur = next(o for o in occurrences if o["id_tache"] == id_de("ASPIRATEUR"))

    reponse = client.post(f"/occurrences/{aspirateur['id_occurrence']}/reporter",
                          headers=thomas, json={})

    assert reponse.status_code == 200
    assert reponse.json()["statut"] == "a_placer"
    # Repoussée d'un jour au moins : la nouvelle échéance passe l'ancienne.
    assert reponse.json()["echeance_max"] > aspirateur["echeance_max"]


def test_toute_tache_se_reporte_meme_la_litiere(client, thomas):
    """TAC-29 : « ne se décale pas » est une description pour HAL, pas un refus."""
    client.post("/planning/placer", headers=thomas)
    occurrences = client.get("/occurrences", headers=thomas).json()
    litiere = next(o for o in occurrences if o["id_tache"] == id_de("LITIERE_CROTTES"))

    reponse = client.post(f"/occurrences/{litiere['id_occurrence']}/reporter",
                          headers=thomas, json={})
    assert reponse.status_code == 200
    assert reponse.json()["statut"] == "a_placer"


def test_le_refus_recree_une_tache_non_assignee(client, thomas):
    client.post("/planning/placer", headers=thomas)
    occurrences = client.get("/occurrences", headers=thomas).json()
    cible = next(o for o in occurrences if o["id_tache"] == id_de("ASPIRATEUR"))

    reprise = client.post(f"/occurrences/{cible['id_occurrence']}/refuser",
                          headers=thomas, json={"motif": "pas envie"}).json()

    assert reprise["id_occurrence"] != cible["id_occurrence"]
    assert reprise["assigne_a"] is None
    assert client.get(f"/occurrences/{cible['id_occurrence']}",
                      headers=thomas).json()["statut"] == "abandonnee"


# ---------------------------------------------------------------------------
# Export iCalendar
# ---------------------------------------------------------------------------

def test_le_flux_ics_demande_une_cle(client):
    assert client.get("/planning.ics").status_code == 401


def test_le_flux_ics_distingue_journee_entiere_et_horaire(client, thomas):
    client.post("/occupations", headers=thomas, json={
        "type": "cours", "libelle": "Cours IDMC",
        "debut": demain(8).isoformat(), "fin": demain(12).isoformat(),
    })
    client.post("/planning/placer", headers=thomas)

    reponse = client.get("/planning.ics", params={"cle": JETON_THOMAS})
    assert reponse.status_code == 200
    assert reponse.headers["content-type"].startswith("text/calendar")

    calendrier = Calendar.from_ical(reponse.content)
    evenements = list(calendrier.walk("VEVENT"))
    assert evenements

    journees = [e for e in evenements
                if e["DTSTART"].params.get("VALUE") == "DATE"]
    horaires = [e for e in evenements
                if e["DTSTART"].params.get("VALUE") != "DATE"]

    # Les rappels de ménage en journée entière, les cours et machines à l'heure.
    assert journees, "les rappels doivent être des événements journée entière"
    assert horaires, "les cours doivent rester des événements horaires"
    assert any("Cours" in str(e["SUMMARY"]) for e in horaires)


def test_le_calendrier_va_plus_loin_que_l_horizon_de_planification(client, thomas):
    # Un cours dans deux mois doit se voir, même si aucune tâche ménagère n'y
    # sera placée : l'horizon d'affichage n'est pas celui de la planification.
    lointain = datetime.now(UTC) + timedelta(days=60)
    client.post("/occupations", headers=thomas, json={
        "type": "cours", "libelle": "Cours de novembre",
        "debut": lointain.replace(hour=8, minute=0, second=0, microsecond=0).isoformat(),
        "fin": lointain.replace(hour=10, minute=0, second=0, microsecond=0).isoformat(),
    })

    flux = client.get("/planning.ics", params={"cle": JETON_THOMAS})
    calendrier = Calendar.from_ical(flux.content)
    titres = [str(e["SUMMARY"]) for e in calendrier.walk("VEVENT")]

    assert any("Cours de novembre" in titre for titre in titres)


def test_le_planning_expose_le_motif_de_placement(client, thomas):
    client.post("/planning/placer", headers=thomas)
    planning = client.get("/planning", headers=thomas).json()
    taches = [ligne for ligne in planning if ligne["nature"] == "tache"]
    assert taches
    assert all(ligne["motif"] for ligne in taches)
