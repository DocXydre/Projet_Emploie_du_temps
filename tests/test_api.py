"""Parcours de l'API contre un vrai PostgreSQL."""

from datetime import UTC, datetime, timedelta

from icalendar import Calendar


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
    codes = {t["code"] for t in taches}

    assert {"ASPIRATEUR", "POUSSIERE", "LITIERE_CROTTES", "LESSIVE_TRAVAIL",
            "GRAND_NETTOYAGE"} <= codes

    poussiere = next(t for t in taches if t["code"] == "POUSSIERE")
    assert poussiere["duree_minutes"] == 5
    assert poussiere["rappel_journee"] is True
    # La poussière déclenche l'aspirateur.
    assert any(d["code"] == "ASPIRATEUR" for d in poussiere["declenche"])

    lessive = next(t for t in taches if t["code"] == "LESSIVE_TRAVAIL")
    assert lessive["rappel_journee"] is False
    assert lessive["reportable"] is False


def test_le_pliage_revient_a_lorette(client, thomas):
    taches = client.get("/taches", headers=thomas).json()
    plier = next(t for t in taches if t["code"] == "PLIER_LINGE")
    profil = client.get("/moi", headers={"X-Cle-Api": "L" * 48}).json()
    assert plier["id_utilisateur_defaut"] == profil["id_utilisateur"]


def test_seul_l_admin_cree_une_tache(client, lorette):
    reponse = client.post("/taches", headers=lorette, json={
        "code": "TEST_REFUS", "libelle": "Interdit", "categorie": "menage",
        "duree_minutes": 10, "periodicite_min_jours": 1, "periodicite_max_jours": 2,
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
    poussiere = next(o for o in occurrences if o["tache_code"] == "POUSSIERE")

    # Les rappels sortent sur une journée entière.
    assert poussiere["rappel_journee"] is True
    assert "faite" in poussiere["actions_possibles"]

    validee = client.post(f"/occurrences/{poussiere['id_occurrence']}/valider",
                          headers=thomas, json={}).json()
    assert validee["statut"] == "faite"
    assert validee["date_faite"] is not None

    toutes = client.get("/occurrences", headers=thomas).json()

    # R21 : la suivante repart de la date réelle.
    suivante = next(o for o in toutes
                    if o["tache_code"] == "POUSSIERE" and o["statut"] != "faite")
    debut_suivante = datetime.fromisoformat(suivante["echeance_min"])
    assert debut_suivante > datetime.now(UTC) + timedelta(days=6)

    # R22 : l'aspirateur a été repositionné, et une seule fois. Le planning
    # étant pré-généré, plusieurs occurrences coexistent : ce qui compte est
    # qu'une seule ait été rattachée à la poussière.
    repositionnes = [o for o in toutes
                     if o["tache_code"] == "ASPIRATEUR"
                     and (o["motif"] or "").startswith("Repositionnée")]
    assert len(repositionnes) == 1


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


def test_lorette_ne_valide_pas_une_tache_de_thomas(client, thomas, lorette):
    client.post("/planning/placer", headers=thomas)
    occurrences = client.get("/occurrences", headers=thomas).json()
    a_thomas = next(o for o in occurrences if o["assigne_a"] == "thomas")

    reponse = client.post(f"/occurrences/{a_thomas['id_occurrence']}/valider",
                          headers=lorette, json={})
    assert reponse.status_code == 403


def test_la_lessive_de_travail_refuse_le_report(client, thomas):
    client.post("/planning/placer", headers=thomas)
    occurrences = client.get("/occurrences", headers=thomas).json()
    lessive = next(o for o in occurrences if o["tache_code"] == "LESSIVE_TRAVAIL")

    reponse = client.post(f"/occurrences/{lessive['id_occurrence']}/reporter",
                          headers=thomas, json={})
    assert reponse.status_code == 409
    assert reponse.json()["code"] == "non_reportable"


def test_le_refus_recree_une_tache_non_assignee(client, thomas):
    client.post("/planning/placer", headers=thomas)
    occurrences = client.get("/occurrences", headers=thomas).json()
    cible = next(o for o in occurrences if o["tache_code"] == "ASPIRATEUR")

    reprise = client.post(f"/occurrences/{cible['id_occurrence']}/refuser",
                          headers=thomas, json={"motif": "pas envie"}).json()

    assert reprise["id_occurrence"] != cible["id_occurrence"]
    assert reprise["assigne_a"] is None
    assert client.get(f"/occurrences/{cible['id_occurrence']}",
                      headers=thomas).json()["statut"] == "abandonnee"


# ---------------------------------------------------------------------------
# Stock
# ---------------------------------------------------------------------------

def test_stock_initial_et_mouvement(client, thomas):
    stock = client.get("/stock", headers=thomas).json()
    tshirt = next(a for a in stock if a["code"] == "TSHIRT")
    assert tshirt["quantite_propre"] == 3
    assert tshirt["quantite_utilisable"] == 3

    apres = client.post("/stock/TSHIRT/mouvement", headers=thomas,
                        json={"type": "salissure", "quantite": 2}).json()
    assert apres["quantite_propre"] == 1


def test_projection_signale_la_rupture(client, thomas):
    for jour in range(1, 5):
        base = datetime.now(UTC) + timedelta(days=jour)
        client.post("/occupations", headers=thomas, json={
            "type": "travail", "libelle": "Shift",
            "debut": base.replace(hour=17, minute=0, second=0, microsecond=0).isoformat(),
            "fin": base.replace(hour=23, minute=0, second=0, microsecond=0).isoformat(),
        })
    client.post("/stock/TSHIRT/mouvement", headers=thomas,
                json={"type": "salissure", "quantite": 2})

    projection = client.get("/stock/projection", headers=thomas).json()
    assert projection["ruptures"], "une rupture devrait être détectée"
    assert any(r["article"] == "TSHIRT" for r in projection["ruptures"])


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

    reponse = client.get("/planning.ics", params={"cle": "T" * 48})
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

    flux = client.get("/planning.ics", params={"cle": "T" * 48})
    calendrier = Calendar.from_ical(flux.content)
    titres = [str(e["SUMMARY"]) for e in calendrier.walk("VEVENT")]

    assert any("Cours de novembre" in titre for titre in titres)


def test_le_planning_expose_le_motif_de_placement(client, thomas):
    client.post("/planning/placer", headers=thomas)
    planning = client.get("/planning", headers=thomas).json()
    taches = [ligne for ligne in planning if ligne["nature"] == "tache"]
    assert taches
    assert all(ligne["motif"] for ligne in taches)
