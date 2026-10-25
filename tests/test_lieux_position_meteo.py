"""Lieux, position, soirée et météo                         (partie H, lots 20 à 22)

Aucun service extérieur n'est appelé : la Géoplateforme, OSRM et Open-Meteo
sont remplacés par des faux, et HAL par un enregistreur des questions qu'on lui
fait poser. Ce qu'on vérifie, c'est ce que tient la base et ce que décide le
serveur : quel lieu, quel trajet, quelle question, à quel HAL, et une seule fois.
"""

from datetime import UTC, datetime, timedelta

import pytest

from api import lieux, meteo, position
from api.coach import appel, foyer, outils
from tests.test_coach import lieu, plan, proposer, u  # noqa: F401 - fixture
from tests.test_ensemble import PARIS, _id, sql, un

# Des adresses inventées, à Nancy et dans les Vosges.
ADRESSES = {
    "foyer": {"adresse": "1 Rue du Foyer 54000 Nancy", "latitude": 48.6900,
              "longitude": 6.1800, "type": "housenumber", "score": 0.95},
    "salle": {"adresse": "15 Rue de la Salle 54000 Nancy", "latitude": 48.6930,
              "longitude": 6.1850, "type": "housenumber", "score": 0.95},
    "ecole": {"adresse": "2 Rue de l'Ecole 54000 Nancy", "latitude": 48.6700,
              "longitude": 6.1600, "type": "housenumber", "score": 0.95},
    "lusse": {"adresse": "Lusse", "latitude": 48.2898, "longitude": 7.1141,
              "type": "municipality", "score": 0.93},
    "ville": {"adresse": "Nancy", "latitude": 48.69, "longitude": 6.18,
              "type": "municipality", "score": 0.9},
}


@pytest.fixture(autouse=True)
def sans_internet(monkeypatch):
    """Les trois services, en faux. Un trajet vaut une minute par 100 m à vol d'oiseau."""
    def chercher(texte):
        cle = texte.split()[0].lower()
        if cle not in ADRESSES:
            raise lieux.AdresseIntrouvable(f"Aucune adresse trouvée pour « {texte} »")
        return dict(ADRESSES[cle])

    def calculer(lat1, lon1, lat2, lon2, mode):
        _, metres = lieux.estimation(lat1, lon1, lat2, lon2, mode)
        return max(1, metres // 100), metres, False

    monkeypatch.setattr(lieux, "chercher_adresse", chercher)
    monkeypatch.setattr(lieux, "calculer", calculer)
    monkeypatch.setattr(lieux, "adresse_proche", lambda lat, lon: "Là où tu es")
    monkeypatch.setattr(meteo, "_interroger", lambda url, params: None)


@pytest.fixture
def questions(monkeypatch):
    """HAL, remplacé : chaque appel est noté, et répond comme si tout allait bien."""
    poses = []

    def appeler(demande):
        poses.append(demande)
        return {"message": "?"}
    monkeypatch.setattr(appel, "appeler_coach", appeler)
    monkeypatch.setattr(position, "_comptes_suivis", lambda: sql(
        "SELECT id_utilisateur, pseudo, coach_actif FROM utilisateur "
        "WHERE actif AND position_sue(id_utilisateur)"))
    return poses


def adresses(compte: int) -> dict[str, int]:
    """Le foyer, la salle et l'école de Thomas, et Lusse où il dort."""
    return {
        "foyer": lieux.noter_lieu(compte, nom="Chez nous", adresse="foyer", nature="foyer")
        ["id_lieu_connu"],
        "salle": lieux.noter_lieu(compte, adresse="salle", id_lieu_sport=lieu("SALLE"),
                                  mode_trajet="pied")["id_lieu_connu"],
        "ecole": lieux.noter_lieu(compte, nom="La fac", adresse="ecole", nature="etudes")
        ["id_lieu_connu"],
        "lusse": lieux.noter_lieu(compte, nom="Lusse", adresse="lusse", nature="sejour",
                                  mode_trajet="voiture")["id_lieu_connu"],
    }


def dans(seance: int, minutes: float) -> None:
    """La séance commence dans tant de minutes, en temps réel : `reculer` compte en
    heure de Paris, et un passage à l'heure d'hiver décalerait la séance d'une heure."""
    sql("UPDATE occurrence SET debut_seance = now() + make_interval(mins => %s), "
        "creneau = tstzrange(now() + make_interval(mins => %s), "
        "                    now() + make_interval(mins => %s + 60), '[)'), "
        "fenetre = tstzrange(now() - INTERVAL '1 day', now() + INTERVAL '2 days', '[)') "
        "WHERE id_occurrence = %s", minutes, minutes, minutes, seance)


def etre(compte: int, ou: str, il_y_a: timedelta = timedelta(0), precision: float = 10) -> dict:
    a = ADRESSES[ou]
    return position.recevoir(compte, a["latitude"], a["longitude"], precision,
                             datetime.now(UTC) - il_y_a, "toujours", True)


# ---------------------------------------------------------------------------
# Les lieux connus                                             (ADR, lot 20)
# ---------------------------------------------------------------------------

def test_une_adresse_de_salle_donne_le_trajet_de_la_seance(u):  # noqa: F811
    ids = adresses(u)
    assert un("SELECT id_lieu_connu FROM lieu_sport WHERE code = 'SALLE'") == ids["salle"]
    # Seul le foyer est commun ; la salle, l'école et Lusse sont à Thomas (ADR-1).
    communs = {r["nom"] for r in sql("SELECT nom FROM lieu_connu WHERE id_foyer IS NOT NULL")}
    assert communs == {"Chez nous"}
    depuis_le_foyer = un("SELECT minutes FROM trajet_calcule WHERE id_depart = %s "
                         "AND id_arrivee = %s AND mode = 'pied'", ids["foyer"], ids["salle"])
    assert depuis_le_foyer is not None
    # Un jour sans cours ni absence, la séance part du foyer (ADR-9).
    assert un("SELECT trajet_minutes(%s, jour_de(now()) + 3, %s)", u, lieu("SALLE")) \
        == depuis_le_foyer


def test_un_jour_a_lusse_le_trajet_part_de_lusse(u):  # noqa: F811
    ids = adresses(u)
    jour = un("SELECT jour_de(now()) + 4")
    sql("INSERT INTO absence (id_utilisateur, periode, lieu, id_lieu_connu) "
        "VALUES (%s, tstzrange(debut_jour(%s::DATE - 1), debut_jour(%s::DATE + 2)), "
        "'Lusse', %s)", u, jour, jour, ids["lusse"])
    lieux.completer_trajets(u)
    depuis_lusse = un("SELECT minutes FROM trajet_calcule WHERE id_depart = %s "
                      "AND id_arrivee = %s", ids["lusse"], ids["salle"])
    assert un("SELECT trajet_minutes(%s, %s, %s)", u, jour, lieu("SALLE")) == depuis_lusse
    # Plus d'une heure : HAL le lit et juge (ADR-10) ; la base ne l'interdit pas.
    assert depuis_lusse > 60


def test_sans_adresse_les_minutes_saisies_restent(u):  # noqa: F811
    assert un("SELECT trajet_minutes(%s, jour_de(now()) + 3, %s)", u, lieu("SALLE")) == \
        un("SELECT minutes_domicile FROM lieu_sport WHERE code = 'SALLE'")


def test_une_commune_ne_suffit_pas_pour_une_salle(u):  # noqa: F811
    with pytest.raises(lieux.AdresseIntrouvable, match="commune entière"):
        lieux.noter_lieu(u, adresse="ville", id_lieu_sport=lieu("SALLE"))
    lusse = lieux.noter_lieu(u, nom="Lusse", adresse="lusse", nature="sejour")
    assert lusse["rayon_m"] == lieux.RAYON_D_UNE_COMMUNE


def test_corriger_l_adresse_refait_les_trajets(client, thomas, u):  # noqa: F811
    ids = adresses(u)
    avant = un("SELECT count(*) FROM trajet_calcule WHERE id_arrivee = %s", ids["salle"])
    reponse = client.patch(f"/appli/lieux/{ids['salle']}", headers=thomas,
                           json={"adresse": "ecole"})
    assert reponse.status_code == 200, reponse.text
    assert reponse.json()["adresse"] == ADRESSES["ecole"]["adresse"]
    assert un("SELECT count(*) FROM trajet_calcule WHERE id_arrivee = %s", ids["salle"]) == avant
    # Une adresse introuvable est refusée, avec son motif (ADR-4).
    refus = client.patch(f"/appli/lieux/{ids['salle']}", headers=thomas,
                         json={"adresse": "nulle part"})
    assert refus.status_code == 422
    assert refus.json()["code"] == "adresse_introuvable"


def test_l_autre_ne_voit_ni_mes_lieux_ni_ma_position(client, thomas, lorette, u):  # noqa: F811
    adresses(u)
    etre(u, "lusse")
    vu = client.get("/appli/lieux", headers=lorette).json()
    assert {x["nom"] for x in vu["lieux"]} == {"Chez nous"}
    assert vu["position"]["sue"] is False
    assert client.get("/appli/lieux", headers=thomas).json()["position"]["lieu"] == "Lusse"
    # Lorette ne peut pas corriger l'école de Thomas.
    ecole = un("SELECT id_lieu_connu FROM lieu_connu WHERE nom = 'La fac'")
    assert client.patch(f"/appli/lieux/{ecole}", headers=lorette,
                        json={"adresse": "salle"}).status_code == 404


def test_la_description_d_un_lieu_garde_ses_versions(u):  # noqa: F811
    ids = adresses(u)
    texte = "Chez mes parents : repos, bons petits plats. Chemins pour le trail."
    rendu, refus = outils.executer_outil(
        "ecrire_description_lieu", u, {"id_lieu_connu": ids["lusse"], "texte": texte},
        {"ecrire_description_lieu"})
    assert not refus, rendu
    # Le même texte ne crée pas de version (MEM-2) ; trop long, refusé (ADR-11).
    outils.executer_outil("ecrire_description_lieu", u,
                          {"id_lieu_connu": ids["lusse"], "texte": texte},
                          {"ecrire_description_lieu"})
    assert un("SELECT count(*) FROM description_lieu") == 1
    rendu, refus = outils.executer_outil(
        "ecrire_description_lieu", u, {"id_lieu_connu": ids["lusse"], "texte": "x" * 1001},
        {"ecrire_description_lieu"})
    assert refus and "1 000" in rendu
    # Quand il y est, la description part avec le contexte de HAL (ADR-12).
    etre(u, "lusse")
    assert texte in lieux.texte_pour_hal(u)


# ---------------------------------------------------------------------------
# La position                                                  (POS, lot 21)
# ---------------------------------------------------------------------------

def test_une_position_a_quarante_metres_est_dans_la_salle(client, thomas, u):  # noqa: F811
    adresses(u)
    pres = {"latitude": ADRESSES["salle"]["latitude"] + 0.00036,
            "longitude": ADRESSES["salle"]["longitude"], "precision_m": 15,
            "autorisation": "toujours", "precise": True}
    rendu = client.post("/appli/position", headers=thomas, json=pres).json()
    assert rendu["lieu"] == "Salle de musculation" and rendu["change"]
    # Un relevé de 300 m ne change rien (POS-3) ; la même salle n'ouvre pas de passage.
    flou = client.post("/appli/position", headers=thomas,
                       json={**pres, "latitude": 48.70, "precision_m": 300}).json()
    assert flou["pris_en_compte"] is False
    assert client.post("/appli/position", headers=thomas, json=pres).json()["change"] is False
    loin = client.post("/appli/position", headers=thomas,
                       json={**pres, "latitude": 48.75}).json()
    assert loin["lieu"] is None and loin["change"]
    assert un("SELECT count(*) FROM presence") == 2


def test_sortir_d_un_lieu_sans_releve(u):  # noqa: F811
    ids = adresses(u)
    etre(u, "salle", il_y_a=timedelta(minutes=30))
    rendu = position.recevoir(u, None, None, None, None, "toujours", True,
                              sortie_de=ids["salle"])
    assert rendu["change"] and rendu["lieu"] is None
    # Sortir d'un lieu où l'on n'est pas ne change rien.
    assert position.recevoir(u, None, None, None, None, "toujours", True,
                             sortie_de=ids["salle"])["change"] is False


def test_un_releve_en_retard_ne_defait_pas_la_presence(u):  # noqa: F811
    adresses(u)
    etre(u, "salle")
    rendu = etre(u, "foyer", il_y_a=timedelta(hours=1))
    assert rendu["pris_en_compte"] is False
    assert un("SELECT l.nom FROM presence p JOIN lieu_connu l USING (id_lieu_connu) "
              "WHERE upper_inf(p.periode)") == "Salle de musculation"


def test_arrive_a_lusse_le_hal_du_foyer_demande_une_fois(questions, u):  # noqa: F811
    ids = adresses(u)
    etre(u, "foyer", il_y_a=timedelta(hours=3))
    etre(u, "lusse")
    position.controles_de_presence()
    position.controles_de_presence()
    assert len(questions) == 1
    q = questions[0]
    assert (q.hal, q.moment) == ("foyer", "presence") and "Lusse" in q.precision
    # Sa réponse déclare l'absence, avec le lieu : plus rien à demander.
    sql("DELETE FROM question_presence")
    sql("INSERT INTO absence (id_utilisateur, periode, lieu, id_lieu_connu) "
        "VALUES (%s, tstzrange(now() - INTERVAL '1 minute', now() + INTERVAL '2 days'), "
        "'Lusse', %s)", u, ids["lusse"])
    position.controles_de_presence()
    assert len(questions) == 1


def test_rentre_au_foyer_le_retour_se_ferme_a_l_heure_d_arrivee(client, thomas, questions, u):  # noqa: F811
    adresses(u)
    sql("INSERT INTO absence (id_utilisateur, periode, lieu) VALUES "
        "(%s, tstzrange(now() - INTERVAL '2 days', now() + INTERVAL '1 day'), 'Lusse')", u)
    etre(u, "lusse", il_y_a=timedelta(days=1))
    etre(u, "foyer", il_y_a=timedelta(minutes=40))
    position.controles_de_presence()
    assert [(q.hal, "POS-8" in q.precision) for q in questions] == [("foyer", True)]
    arrivee = un("SELECT lower(periode) FROM presence WHERE upper_inf(periode)")
    from api import demandes
    geste = demandes.deposer(u, "absence", {"retour": arrivee.isoformat(),
                                            "motif": "rentré de Lusse"}, geste=True)
    demandes.accepter(u, geste["id_demande"])
    assert un("SELECT upper(periode) FROM absence WHERE id_utilisateur = %s", u) == arrivee


def test_pas_a_la_salle_quinze_minutes_apres_le_hal_sport_demande(questions, u, plan):  # noqa: F811
    adresses(u)
    seance = proposer(u, dans=1)
    dans(seance, -18)
    etre(u, "foyer", il_y_a=timedelta(hours=2))
    position.controles_de_presence()
    assert [(q.hal, q.moment, q.id_occurrence) for q in questions] == \
        [("sport", "absent", seance)]
    # À la salle, pas de question.
    sql("DELETE FROM question_presence")
    etre(u, "salle")
    position.controles_de_presence()
    assert len(questions) == 1


def test_pas_a_l_ecole_pendant_un_cours(questions, u):  # noqa: F811
    adresses(u)
    source = un("SELECT id_source FROM source ORDER BY id_source LIMIT 1")
    cours = un("INSERT INTO occupation (id_utilisateur, id_source, type, libelle, periode, "
               "cle_externe) VALUES (%s, %s, 'cours', 'Algèbre', "
               "tstzrange(now() - INTERVAL '20 minutes', now() + INTERVAL '1 hour'), "
               "'cours-algebre') RETURNING id_occupation", u, source)
    etre(u, "foyer", il_y_a=timedelta(hours=2))
    position.controles_de_presence()
    assert [(q.hal, q.moment) for q in questions] == [("foyer", "presence")]
    assert "Algèbre" in questions[0].precision
    # Annulé : il quitte le planning et sa clé est gardée pour la collecte.
    sql("SELECT annuler_cours(%s, %s)", u, cours)
    assert un("SELECT count(*) FROM occupation WHERE id_occupation = %s", cours) == 0
    assert un("SELECT cle_externe FROM cours_annule") == "cours-algebre"


def test_un_creneau_pose_a_la_main_ne_s_annule_pas_comme_un_cours(u):  # noqa: F811
    source = un("SELECT id_source FROM source ORDER BY id_source LIMIT 1")
    creneau = un("INSERT INTO occupation (id_utilisateur, id_source, type, libelle, periode) "
                 "VALUES (%s, %s, 'cours', 'Révision', "
                 "tstzrange(now(), now() + INTERVAL '1 hour')) RETURNING id_occupation",
                 u, source)
    rendu, refus = outils.executer_outil(
        "annuler_cours", u, {"id_occupation": creneau}, {"annuler_cours"},
        {"annuler_cours": foyer.OUTIL_ANNULER_COURS})
    assert refus and "à la main" in rendu


def test_sans_position_sue_aucune_question(questions, u):  # noqa: F811
    adresses(u)
    etre(u, "lusse")
    sql("UPDATE position_actuelle SET autorisation = 'utilisation'")
    position.controles_de_presence()
    sql("UPDATE position_actuelle SET autorisation = 'toujours', "
        "ecrit_le = now() - INTERVAL '3 days'")
    position.controles_de_presence()
    assert questions == []


def test_la_reponse_a_une_question_va_au_hal_qui_l_a_posee(u):  # noqa: F811
    from api import aiguillage
    sql("INSERT INTO echange (id_utilisateur, auteur, moment, contenu, hal, modele, "
        "version_dossier) VALUES (%s, 'coach', 'presence', 'Tu restes à Lusse ?', 'foyer', "
        "'faux', 'v')", u)
    assert aiguillage.choisir("oui jusqu'à dimanche", u).hal == "maison"
    sql("INSERT INTO echange (id_utilisateur, auteur, moment, contenu, hal, modele, "
        "version_dossier) VALUES (%s, 'coach', 'soiree', 'Ta soirée ?', 'sport', 'faux', 'v')",
        u)
    assert aiguillage.choisir("trois bières", u).par == "question"
    # Une fois répondu, la question ne tranche plus.
    sql("INSERT INTO echange (id_utilisateur, auteur, moment, contenu, hal) "
        "VALUES (%s, 'utilisateur', 'chat', 'trois bières', 'sport')", u)
    assert aiguillage.question_en_attente(u) is None


# ---------------------------------------------------------------------------
# La soirée                                                    (SOI, lot 21)
# ---------------------------------------------------------------------------

def test_a_minuit_ailleurs_c_est_une_soiree_pas_a_lusse(u):  # noqa: F811
    adresses(u)
    lorette = _id("lorette")
    sql("UPDATE utilisateur SET coach_actif = TRUE WHERE id_utilisateur = %s", lorette)
    minuit = un("SELECT debut_jour(jour_de(now()))")
    a = ADRESSES["foyer"]
    position.recevoir(lorette, a["latitude"], a["longitude"], 10,
                      minuit - timedelta(hours=3), "toujours", True)
    position.recevoir(u, 48.70, 6.20, 10, minuit - timedelta(hours=2), "toujours", True)
    assert un("SELECT reperer_les_soirees(%s)", minuit) == 1
    assert un("SELECT id_utilisateur FROM soiree") == u
    assert un("SELECT reperer_les_soirees(%s)", minuit) == 0


def test_au_reveil_hal_demande_comment_s_est_passee_la_soiree(questions, u):  # noqa: F811
    adresses(u)
    etre(u, "foyer", il_y_a=timedelta(hours=1))
    sql("INSERT INTO soiree (id_utilisateur, nuit, origine) "
        "VALUES (%s, jour_de(now()) - 1, 'position')", u)
    sql("UPDATE utilisateur SET heure_bilan = '23:59' WHERE id_utilisateur = %s", u)
    position.controles_de_presence()
    assert questions == []
    # La montre a vu la fin de la nuit il y a vingt minutes.
    fin = datetime.now(UTC) - timedelta(minutes=20)
    if fin.astimezone(PARIS).date() == datetime.now(PARIS).date():
        sql("INSERT INTO sommeil_phase (id_utilisateur, cle_externe, phase, periode) "
            "VALUES (%s, 'nuit', 'leger', tstzrange(%s - INTERVAL '6 hours', %s))", u, fin, fin)
        position.controles_de_presence()
        assert [(q.hal, q.moment) for q in questions] == [("sport", "soiree")]


def test_noter_une_soiree_racontee(u):  # noqa: F811
    rendu, refus = outils.executer_outil(
        "noter_soiree", u, {"verres": 5, "couche_a": "03:00", "ressenti": 2,
                            "commentaire": "tête lourde"}, {"noter_soiree"})
    assert not refus, rendu
    s = sql("SELECT statut, verres, ressenti, couche_a FROM soiree")[0]
    assert (s["statut"], s["verres"], s["ressenti"]) == ("racontee", 5, 2)
    assert s["couche_a"].astimezone(PARIS).hour == 3
    # La soirée entre dans le contexte de HAL (SOI-5) ; jamais dans celui de l'autre.
    from api.coach import contexte
    assert "verres d'alcool 5" in contexte.texte(u)
    assert "verres" not in contexte.soirees(_id("lorette"))


# ---------------------------------------------------------------------------
# La météo                                                     (MTO, lot 22)
# ---------------------------------------------------------------------------

def _heure(pluie=0.0, temperature=12.0, ressenti=10.0, vent=10.0, rafales=20.0, proba=10):
    return {"heure": datetime.now(UTC).replace(minute=0, second=0, microsecond=0),
            "temperature": temperature, "ressenti": ressenti, "pluie_mm": pluie,
            "pluie_proba": proba, "vent_kmh": vent, "rafales_kmh": rafales,
            "direction_deg": 270, "humidite": 80, "code_temps": 3}


def test_les_seuils_fixes():
    assert meteo.seuils_franchis([_heure()]) == []
    assert meteo.seuils_franchis([_heure(pluie=2.0)])[0].startswith("pluie")
    assert meteo.seuils_franchis([_heure(ressenti=-2)])[0].startswith("gel")
    assert meteo.seuils_franchis([_heure(rafales=65)])[0].startswith("vent fort")
    assert meteo.seuils_franchis([_heure(temperature=32)])[0].startswith("canicule")


def test_le_vent_rapporte_au_trace():
    # Un aller-retour est-ouest de 2 km, vent d'est : l'aller face au vent, plus lent.
    debut = datetime(2026, 10, 20, 8, tzinfo=UTC)
    points, t = [], debut
    for i in range(21):
        points.append({"instant": t, "latitude": 48.69, "longitude": 6.18 + i * 0.00136})
        t += timedelta(seconds=36)
    for i in range(20, -1, -1):
        points.append({"instant": t, "latitude": 48.69, "longitude": 6.18 + i * 0.00136})
        t += timedelta(seconds=30)
    rendu = meteo.vent_sur_le_trace(points, provenance_deg=90, vent_kmh=25)
    assert rendu["part_face"] == pytest.approx(0.5, abs=0.05)
    assert rendu["part_dos"] == pytest.approx(0.5, abs=0.05)
    assert rendu["allure_face_s"] > rendu["allure_dos_s"]
    assert abs(rendu["composante_face_kmh"]) < 2


def test_une_heure_avant_la_pluie_fait_appeler_hal(monkeypatch, questions, u, plan):  # noqa: F811
    adresses(u)
    seance = proposer(u, dans=1, discipline="course", exercices=None, duree=45)
    dans(seance, 54)
    pluie = []
    monkeypatch.setattr(meteo, "prevision", lambda *a, **k: pluie)
    pluie[:] = [_heure()]
    position.controles_meteo()
    assert questions == []
    # Le contrôle est fait : une prévision qui tourne ensuite ne refait pas d'appel.
    sql("DELETE FROM question_presence")
    pluie[:] = [_heure(pluie=2.0)]
    position.controles_meteo()
    position.controles_meteo()
    assert [(q.hal, q.moment, q.id_occurrence) for q in questions] == \
        [("sport", "meteo", seance)]
    assert "pluie" in questions[0].precision


def test_la_meteo_des_seances_part_en_nombres(client, thomas, monkeypatch, u, plan):  # noqa: F811
    adresses(u)
    seance = proposer(u, dans=1, discipline="course", exercices=None, duree=45)
    dans(seance, 180)
    monkeypatch.setattr(meteo, "prevision", lambda *a, **k: [_heure(pluie=1.5)])
    rendu = client.get("/appli/meteo/seances", headers=thomas).json()
    assert [x["id_occurrence"] for x in rendu] == [seance]
    assert rendu[0]["a_l_heure"]["temperature"] == 12.0
    assert rendu[0]["seuils"][0].startswith("pluie")


def test_open_meteo_muet_ne_note_rien(monkeypatch, questions, u, plan):  # noqa: F811
    adresses(u)
    seance = proposer(u, dans=1, discipline="course", exercices=None, duree=45)
    dans(seance, 54)
    position.controles_meteo()
    assert questions == [] and un("SELECT count(*) FROM question_presence") == 0


def test_la_meteo_d_une_course(client, thomas, lorette, monkeypatch, u):  # noqa: F811
    activite = un(
        "INSERT INTO activite_sante (id_utilisateur, cle_externe, type, discipline, periode, "
        "duree_secondes, distance_m) VALUES (%s, 'course-1', 'running', 'course', "
        "tstzrange(now() - INTERVAL '2 hours', now() - INTERVAL '1 hour'), 3600, 10000) "
        "RETURNING id_activite", u)
    debut = un("SELECT lower(periode) FROM activite_sante WHERE id_activite = %s", activite)
    for i in range(40):
        sql("INSERT INTO activite_trace (id_activite, instant, latitude, longitude) "
            "VALUES (%s, %s, 48.69, %s)", activite, debut + timedelta(seconds=30 * i),
            6.18 + i * 0.0014)
    monkeypatch.setattr(meteo, "passee", lambda *a: {**_heure(vent=28), "direction_deg": 90})
    rendu = client.get(f"/appli/meteo/activite/{activite}", headers=thomas)
    assert rendu.status_code == 200, rendu.text
    assert rendu.json()["part_face"] > 0.9
    assert "face au vent" in rendu.json()["en_clair"]
    assert client.get(f"/appli/meteo/activite/{activite}", headers=lorette).status_code == 404


# ---------------------------------------------------------------------------
# Les lieux de sport décrits                        (ADR-15 à ADR-18, DEM-7)
# ---------------------------------------------------------------------------

def deux_salles(compte: int) -> tuple[int, int]:
    """La salle d'avant à son adresse, et une seconde, ouverte jour et nuit."""
    proche = lieux.noter_lieu(compte, adresse="salle", id_lieu_sport=lieu("SALLE"),
                              description="Blindée le soir : cardio et tapis")
    loin = lieux.noter_lieu(compte, nom="Fitness 24/24", adresse="ecole", nature="sport",
                            description="Ouverte 24 h sur 24 : mes séances de muscu")
    return proche["id_lieu_connu"], loin["id_lieu_connu"]


def test_un_lieu_de_sport_donne_par_adresse_a_son_lieu_de_placement(u):  # noqa: F811
    _, loin = deux_salles(u)
    s = sql("SELECT code, heure_min, heure_max, marge_minutes FROM lieu_sport "
            "WHERE id_lieu_connu = %s", loin)[0]
    assert s["code"] == f"LIEU_{loin}"
    assert (str(s["heure_min"]), str(s["heure_max"]), s["marge_minutes"]) == \
        ("00:00:00", "23:59:00", lieux.BATTEMENT_MINUTES)
    # Le noter de nouveau ne crée pas un second lieu de placement.
    lieux.noter_lieu(u, nom="Fitness 24/24", nature="sport")
    assert un("SELECT count(*) FROM lieu_sport WHERE id_lieu_connu = %s", loin) == 1


def test_les_lieux_de_chaque_discipline_se_deduisent_des_adresses(u):  # noqa: F811
    # Avant toute adresse de sport, le choix d'avant tient (ADR-18).
    avant = {(r["discipline"], r["id_lieu"]) for r in sql(
        "SELECT discipline, id_lieu FROM lieux_de_sport(%s)", u)}
    assert ("musculation", lieu("SALLE")) in avant
    lieux.noter_lieu(u, nom="Chez nous", adresse="foyer", nature="foyer")
    _, loin = deux_salles(u)
    lieu_loin = un("SELECT id_lieu FROM lieu_sport WHERE id_lieu_connu = %s", loin)
    rangs = sql("SELECT discipline, id_lieu, rang FROM lieux_de_sport(%s) "
                "ORDER BY discipline, rang", u)
    par = {}
    for r in rangs:
        par.setdefault(r["discipline"], []).append(r["id_lieu"])
    # Chaque salle pour chaque discipline, la plus proche du foyer d'abord ; la course
    # dehors en tête de la course.
    assert par["musculation"] == [lieu("SALLE"), lieu_loin]
    assert par["cardio"] == [lieu("SALLE"), lieu_loin]
    assert par["course"] == [lieu("COURSE"), lieu("SALLE"), lieu_loin]
    # La base accepte la salle éloignée pour la musculation, et refuse la piscine,
    # qui n'a pas d'adresse.
    assert un("SELECT lieu_de_discipline(%s, 'musculation', %s)", u, lieu_loin) == lieu_loin
    with pytest.raises(Exception, match="ne fait pas partie"):
        sql("SELECT lieu_de_discipline(%s, 'musculation', %s)", u, lieu("PISCINE_SUAPS"))


def test_hal_lit_la_description_des_salles(u):  # noqa: F811
    lieux.noter_lieu(u, nom="Chez nous", adresse="foyer", nature="foyer")
    deux_salles(u)
    from api.coach import contexte
    texte = contexte.texte(u)
    assert "Ouverte 24 h sur 24 : mes séances de muscu" in texte
    assert "Blindée le soir : cardio et tapis" in texte
    assert "horaires dans sa description" in texte


def test_le_demarrage_ajoute_les_adresses(client, thomas, lorette, u):  # noqa: F811
    corps = {"nom": "Chez mes parents", "adresse": "lusse", "nature": "sejour",
             "description": "Je me repose, il y a des chemins pour le trail"}
    reponse = client.post("/appli/lieux", headers=thomas, json=corps)
    assert reponse.status_code == 201, reponse.text
    assert reponse.json()["description"] == corps["description"]
    # Refaire l'étape met à jour le même lieu, sans doublon.
    client.post("/appli/lieux", headers=thomas, json={**corps, "description": "Repos"})
    assert un("SELECT count(*) FROM lieu_connu WHERE nom = 'Chez mes parents'") == 1
    assert client.get("/appli/lieux", headers=thomas).json()["lieux"][0]["description"] == \
        "Repos"
    # Une salle donnée au démarrage devient un lieu de sport.
    salle = client.post("/appli/lieux", headers=thomas, json={
        "nom": "Ma salle", "adresse": "salle", "nature": "sport"}).json()
    assert un("SELECT count(*) FROM lieu_sport WHERE id_lieu_connu = %s",
              salle["id_lieu_connu"]) == 1
    # Une adresse introuvable est dite.
    refus = client.post("/appli/lieux", headers=thomas, json={**corps, "adresse": "nulle part"})
    assert refus.status_code == 422 and refus.json()["code"] == "adresse_introuvable"
    # Lorette ne voit ni les parents de Thomas, ni leur description.
    assert "Chez mes parents" not in {
        x["nom"] for x in client.get("/appli/lieux", headers=lorette).json()["lieux"]}


def test_l_etape_des_adresses_du_demarrage(client, lorette):
    from api.coach import demarrage
    lo = _id("lorette")
    sql("INSERT INTO profil (id_utilisateur, date_naissance, sexe, taille_cm, "
        "niveau_musculation, niveau_course) VALUES (%s, '2000-01-01', 'femme', 165, "
        "'debutant', 'debutant')", lo)
    client.post("/appli/demarrage/limitations-faites", headers=lorette)
    assert demarrage.bloc_manquant(lo) == "lieux"
    # Le foyer seul ne suffit pas : l'étape attend qu'on la passe.
    client.post("/appli/lieux", headers=lorette,
                json={"nom": "Chez nous", "adresse": "foyer", "nature": "foyer"})
    assert demarrage.bloc_manquant(lo) == "lieux"
    # Passée sans salle, elle est faite : la course dehors suffit (DEM-7).
    client.post("/appli/demarrage/adresses-faites", headers=lorette)
    assert demarrage.bloc_manquant(lo) == "objectif"
    assert {r["discipline"] for r in sql(
        "SELECT discipline FROM lieux_de_sport(%s)", lo)} == {"course"}
