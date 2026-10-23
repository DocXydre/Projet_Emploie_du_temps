"""Tout le détail de Santé : séries, découpage, tracé, quotidien, sommeil
(SAN-11 à SAN-16, migration 069)."""

# ruff: noqa: F811 (les fixtures de test_coach sont importées puis demandées)

import json
import uuid
from datetime import datetime, timedelta

from tests.test_coach import u  # noqa: F401
from tests.test_ensemble import PARIS, sql, un


def _seance(client, entete, *, debut, minutes=40, source="Apple Watch de Thomas",
            appareil="Watch", type_="running") -> str:
    cle = str(uuid.uuid4()).upper()
    details = {"source": source}
    if appareil:
        details["appareil"] = appareil
    rendu = client.put(f"/donnees-sante/activites/{cle}", headers=entete, json={
        "type": type_, "debut": debut.isoformat(),
        "fin": (debut + timedelta(minutes=minutes)).isoformat(),
        "distance_m": 7000, "fc_moyenne": 150, "details": details})
    assert rendu.status_code == 200, rendu.text
    return cle


def _debut(heures=3) -> datetime:
    return datetime.now(PARIS).replace(microsecond=0) - timedelta(hours=heures)


# --- SAN-11, SAN-12 : les séries -------------------------------------------------

def test_les_series_d_une_seance_sont_gardees_brutes(client, thomas):
    debut = _debut()
    cle = _seance(client, thomas, debut=debut)
    points = [{"grandeur": "fc", "debut": (debut + timedelta(seconds=5 * i)).isoformat(),
               "valeur": 120 + i % 40} for i in range(400)]
    points += [{"grandeur": "vitesse", "debut": (debut + timedelta(seconds=10 * i)).isoformat(),
                "fin": (debut + timedelta(seconds=10 * i + 10)).isoformat(), "valeur": 3.1}
               for i in range(100)]
    # Écartées : hors bornes, grandeur inconnue, deux heures après la séance.
    points += [{"grandeur": "fc", "debut": (debut + timedelta(minutes=1, seconds=1)).isoformat(),
                "valeur": 300},
               {"grandeur": "humeur", "debut": debut.isoformat(), "valeur": 3},
               {"grandeur": "fc", "debut": (debut + timedelta(hours=2)).isoformat(),
                "valeur": 130}]

    rendu = client.put(f"/donnees-sante/activites/{cle}/series", headers=thomas,
                       json={"series": points})
    assert rendu.status_code == 200, rendu.text
    assert rendu.json() == {"gardees": 500, "ecartees": 3}

    # Renvoyé après une coupure : rien de plus, la valeur est mise à jour.
    points[0]["valeur"] = 99
    rendu = client.put(f"/donnees-sante/activites/{cle}/series", headers=thomas,
                       json={"series": points})
    assert rendu.json()["gardees"] == 500
    assert un("SELECT count(*) FROM activite_serie") == 500
    assert un("SELECT valeur FROM activite_serie WHERE grandeur = 'fc' "
              "ORDER BY debut LIMIT 1") == 99


def test_le_detail_d_une_seance_inconnue_est_refuse(client, thomas):
    rendu = client.put("/donnees-sante/activites/INCONNUE/series", headers=thomas,
                       json={"series": [{"grandeur": "fc", "debut": _debut().isoformat(),
                                         "valeur": 120}]})
    assert rendu.status_code == 404, rendu.text
    assert "envoie la séance" in rendu.text


def test_un_paquet_trop_gros_est_refuse(client, thomas):
    debut = _debut()
    cle = _seance(client, thomas, debut=debut)
    points = [{"grandeur": "fc", "debut": (debut + timedelta(seconds=i)).isoformat(),
               "valeur": 120} for i in range(5001)]
    rendu = client.put(f"/donnees-sante/activites/{cle}/series", headers=thomas,
                       json={"series": points})
    assert rendu.status_code == 422
    assert un("SELECT count(*) FROM activite_serie") == 0


def test_les_series_de_l_un_ne_vont_pas_chez_l_autre(client, thomas, lorette):
    cle = _seance(client, thomas, debut=_debut())
    rendu = client.put(f"/donnees-sante/activites/{cle}/series", headers=lorette,
                       json={"series": [{"grandeur": "fc", "debut": _debut().isoformat(),
                                         "valeur": 120}]})
    assert rendu.status_code == 404


# --- SAN-13 : le découpage -------------------------------------------------------

def test_le_decoupage_remplace_celui_de_la_meme_sorte(client, thomas):
    debut = _debut()
    cle = _seance(client, thomas, debut=debut)

    def segment(sorte, rang, de, a, **plus):
        return {"sorte": sorte, "rang": rang,
                "debut": (debut + timedelta(minutes=de)).isoformat(),
                "fin": (debut + timedelta(minutes=a)).isoformat(), **plus}

    etapes = [segment("etape", 1, 0, 15, libelle="Échauffement",
                      prevu={"duree_s": 900, "zone": 2}),
              segment("etape", 2, 15, 17, libelle="Fraction 1",
                      prevu={"distance_m": 400, "objectif_s": 112}),
              segment("etape", 3, 17, 18, libelle="Récupération")]
    kilometres = [segment("kilometre", k, 6 * (k - 1), 6 * k, distance_m=1000)
                  for k in range(1, 5)]
    rendu = client.put(f"/donnees-sante/activites/{cle}/segments", headers=thomas,
                       json={"segments": etapes + kilometres})
    assert rendu.json() == {"gardees": 7, "ecartees": 0}

    # Les étapes renvoyées remplacent les étapes ; les kilomètres restent.
    rendu = client.put(f"/donnees-sante/activites/{cle}/segments", headers=thomas,
                       json={"segments": etapes[:2] + [segment("etape", 3, 18, 18)]})
    assert rendu.json() == {"gardees": 2, "ecartees": 1}
    assert un("SELECT count(*) FROM activite_segment WHERE sorte = 'etape'") == 2
    assert un("SELECT count(*) FROM activite_segment WHERE sorte = 'kilometre'") == 4
    assert un("SELECT prevu ->> 'objectif_s' FROM activite_segment "
              "WHERE sorte = 'etape' AND rang = 2") == "112"


# --- SAN-14 : le tracé -----------------------------------------------------------

def test_le_trace_est_garde_point_par_point(client, thomas):
    debut = _debut()
    cle = _seance(client, thomas, debut=debut)
    points = [{"instant": (debut + timedelta(seconds=2 * i)).isoformat(),
               "latitude": 48.6950 + i * 0.0001, "longitude": 6.1830, "altitude_m": 205.4,
               "precision_m": 4.2, "vitesse_ms": 3.0} for i in range(300)]
    points.append({"instant": debut.isoformat(), "latitude": 95, "longitude": 6.18})
    rendu = client.put(f"/donnees-sante/activites/{cle}/trace", headers=thomas,
                       json={"points": points})
    assert rendu.json() == {"gardees": 300, "ecartees": 1}
    assert client.put(f"/donnees-sante/activites/{cle}/trace", headers=thomas,
                      json={"points": points}).json()["gardees"] == 300
    assert un("SELECT count(*) FROM activite_trace") == 300


def test_supprimer_la_seance_emporte_son_detail(client, thomas, u):
    debut = _debut()
    cle = _seance(client, thomas, debut=debut)
    client.put(f"/donnees-sante/activites/{cle}/series", headers=thomas, json={"series": [
        {"grandeur": "fc", "debut": debut.isoformat(), "valeur": 120}]})
    client.put(f"/donnees-sante/activites/{cle}/trace", headers=thomas, json={"points": [
        {"instant": debut.isoformat(), "latitude": 48.69, "longitude": 6.18}]})
    sql("SELECT reinitialiser_coach(%s)", u)
    assert un("SELECT count(*) FROM activite_serie") == 0
    assert un("SELECT count(*) FROM activite_trace") == 0


# --- SAN-15 : le quotidien et les doublons ---------------------------------------

def test_le_quotidien_est_garde_avec_sa_source(client, thomas, u):
    maintenant = datetime.now(PARIS).replace(microsecond=0)
    lot = [
        {"cle": "FC-1", "grandeur": "fc", "debut": (maintenant - timedelta(hours=5)).isoformat(),
         "valeur": 64, "source": "Apple Watch de Thomas", "appareil": "Watch"},
        {"cle": "POIDS-1", "grandeur": "poids",
         "debut": (maintenant - timedelta(days=2)).isoformat(),
         "valeur": 72.4, "source": "Withings"},
        {"cle": "VO2-1", "grandeur": "vo2max",
         "debut": (maintenant - timedelta(days=1)).isoformat(),
         "valeur": 47.3, "source": "Apple Watch de Thomas", "appareil": "Watch"},
        # Écartées : une grandeur de séance, une valeur absurde, une mesure du futur.
        {"cle": "X-1", "grandeur": "vitesse", "debut": maintenant.isoformat(), "valeur": 3},
        {"cle": "X-2", "grandeur": "spo2", "debut": maintenant.isoformat(), "valeur": 0.97},
        {"cle": "X-3", "grandeur": "fc", "debut": (maintenant + timedelta(days=1)).isoformat(),
         "valeur": 60},
    ]
    rendu = client.put("/donnees-sante/echantillons", headers=thomas, json={"echantillons": lot})
    assert rendu.status_code == 200, rendu.text
    assert rendu.json() == {"gardees": 3, "ecartees": 3}

    lot[1]["valeur"] = 72.1
    client.put("/donnees-sante/echantillons", headers=thomas, json={"echantillons": lot})
    assert un("SELECT count(*) FROM echantillon_sante WHERE id_utilisateur = %s", u) == 3
    assert un("SELECT valeur FROM echantillon_sante WHERE cle_externe = 'POIDS-1'") == 72.1
    assert un("SELECT de_la_montre FROM echantillon_sante WHERE cle_externe = 'FC-1'") is True
    assert un("SELECT de_la_montre FROM echantillon_sante WHERE cle_externe = 'POIDS-1'") is False


def test_la_lecture_prend_la_montre_d_abord(client, thomas):
    debut = datetime.now(PARIS).replace(microsecond=0) - timedelta(hours=10)
    fin = debut + timedelta(hours=1)
    client.put("/donnees-sante/echantillons", headers=thomas, json={"echantillons": [
        {"cle": "E-MONTRE", "grandeur": "energie", "debut": debut.isoformat(),
         "fin": fin.isoformat(), "valeur": 80, "appareil": "Watch"},
        {"cle": "E-IPHONE", "grandeur": "energie",
         "debut": (debut + timedelta(minutes=20)).isoformat(),
         "fin": (fin + timedelta(minutes=20)).isoformat(), "valeur": 70, "appareil": "iPhone"},
        {"cle": "P-BALANCE", "grandeur": "poids", "debut": debut.isoformat(), "valeur": 72.4},
    ]})
    lus = {ligne["cle_externe"] for ligne in sql("SELECT cle_externe FROM v_echantillon_sante")}
    assert lus == {"E-MONTRE", "P-BALANCE"}
    assert un("SELECT count(*) FROM echantillon_sante") == 3


def test_une_seance_recue_deux_fois_ne_compte_qu_une_fois(client, thomas, u):
    debut = _debut(5)
    # Strava d'abord : elle devient une séance libre (coach actif).
    strava = _seance(client, thomas, debut=debut + timedelta(minutes=1), minutes=38,
                     source="Strava", appareil=None)
    occurrence = un("SELECT id_occurrence FROM activite_sante WHERE cle_externe = %s", strava)
    assert occurrence is not None

    # Puis la montre : elle compte, et reprend la séance.
    montre_cle = str(uuid.uuid4()).upper()
    rendu = client.put(f"/donnees-sante/activites/{montre_cle}", headers=thomas, json={
        "type": "running", "debut": debut.isoformat(),
        "fin": (debut + timedelta(minutes=40)).isoformat(),
        "details": {"source": "Apple Watch de Thomas", "appareil": "Watch"}})
    assert rendu.status_code == 200, rendu.text
    assert rendu.json()["id_occurrence"] == occurrence
    lignes = {ligne["cle_externe"]: ligne for ligne in sql(
        "SELECT cle_externe, id_activite, doublon_de, id_occurrence FROM activite_sante")}
    assert lignes[strava]["doublon_de"] == lignes[montre_cle]["id_activite"]
    assert lignes[strava]["id_occurrence"] is None
    assert lignes[montre_cle]["id_occurrence"] == occurrence

    # Strava renvoyée : elle reste un doublon.
    rendu = client.put(f"/donnees-sante/activites/{strava}", headers=thomas, json={
        "type": "running", "debut": (debut + timedelta(minutes=1)).isoformat(),
        "fin": (debut + timedelta(minutes=39)).isoformat(), "details": {"source": "Strava"}})
    assert rendu.json()["doublon_de"] == lignes[montre_cle]["id_activite"]

    # HAL et l'appli ne voient qu'une séance.
    assert len(client.get("/donnees-sante/jours", headers=thomas).json()
               ["seances_de_la_montre"]) == 1
    recu = client.get("/donnees-sante/reception", headers=thomas).json()
    assert recu["seances"] == 1 and recu["doublons"] == 1


def test_deux_seances_qui_se_suivent_ne_sont_pas_des_doublons(client, thomas):
    debut = _debut(6)
    _seance(client, thomas, debut=debut, minutes=30)
    _seance(client, thomas, debut=debut + timedelta(minutes=25), minutes=30, source="Strava",
            appareil=None)
    assert un("SELECT count(*) FROM activite_sante WHERE doublon_de IS NULL") == 2


# --- SAN-16 : le sommeil ---------------------------------------------------------

def test_le_sommeil_est_garde_phase_par_phase(client, thomas):
    coucher = datetime.now(PARIS).replace(hour=23, minute=28, second=0, microsecond=0) \
        - timedelta(days=2)
    phases, t = [], coucher
    for rang, (phase, minutes) in enumerate([("leger", 22), ("profond", 48), ("leger", 30),
                                             ("paradoxal", 25), ("eveille", 4)]):
        phases.append({"cle": f"S-{rang}", "phase": phase, "debut": t.isoformat(),
                       "fin": (t + timedelta(minutes=minutes)).isoformat(),
                       "source": "Apple Watch de Thomas", "appareil": "Watch"})
        t += timedelta(minutes=minutes)
    phases.append({"cle": "S-X", "phase": "reve", "debut": t.isoformat(),
                   "fin": (t + timedelta(minutes=5)).isoformat()})
    rendu = client.put("/donnees-sante/sommeil", headers=thomas, json={"phases": phases[:5]})
    assert rendu.json() == {"gardees": 5, "ecartees": 0}
    # Une phase inconnue est refusée par l'API avant d'arriver en base.
    assert client.put("/donnees-sante/sommeil", headers=thomas,
                      json={"phases": phases}).status_code == 422
    assert client.put("/donnees-sante/sommeil", headers=thomas,
                      json={"phases": phases[:5]}).json()["gardees"] == 5
    assert un("SELECT count(*) FROM sommeil_phase") == 5
    recu = client.get("/donnees-sante/reception", headers=thomas).json()
    assert recu["phases_sommeil"] == 5


# --- SAN-15 : les doublons reçus avant la migration 069 -------------------------

def _ancienne(u, cle, debut, minutes, source, appareil=None):
    """Une séance reçue avant 069 : pas de départage, rattachée comme alors."""
    details = {"source": source, **({"appareil": appareil} if appareil else {})}
    ident = un("""INSERT INTO activite_sante (id_utilisateur, cle_externe, type, discipline,
                                              periode, duree_secondes, details)
                  VALUES (%s, %s, 'running', 'course', tstzrange(%s, %s), %s, %s::JSONB)
                  RETURNING id_activite""",
               u, cle, debut, debut + timedelta(minutes=minutes), minutes * 60,
               json.dumps(details))
    sql("SELECT rattacher_activite(%s)", ident)
    return ident


def test_les_anciens_doublons_se_departagent_une_fois(u):
    debut = _debut(30)
    strava = _ancienne(u, "STRAVA", debut, 40, "Strava")
    montre = _ancienne(u, "MONTRE", debut + timedelta(seconds=20), 40,
                       "Apple Watch de Thomas", "Watch")
    seance_strava = un("SELECT id_occurrence FROM activite_sante WHERE id_activite = %s", strava)
    seance_montre = un("SELECT id_occurrence FROM activite_sante WHERE id_activite = %s", montre)
    assert seance_strava and seance_montre and seance_strava != seance_montre

    rendu = un("SELECT departager_activites_existantes()")
    assert rendu == {"doublons": 1, "seances_retirees": 1}
    assert un("SELECT doublon_de FROM activite_sante WHERE id_activite = %s", strava) == montre
    assert un("SELECT count(*) FROM occurrence WHERE id_occurrence = %s", seance_strava) == 0
    assert un("SELECT id_occurrence FROM activite_sante WHERE id_activite = %s",
              montre) == seance_montre
    assert un("SELECT departager_activites_existantes()") == {"doublons": 0,
                                                              "seances_retirees": 0}


def test_la_montre_reprend_la_seance_de_l_ancien_doublon(u):
    debut = _debut(30)
    strava = _ancienne(u, "STRAVA", debut, 40, "Strava")
    seance = un("SELECT id_occurrence FROM activite_sante WHERE id_activite = %s", strava)
    # La montre arrivée ensuite, sans séance : elle n'en avait pas trouvé de libre.
    montre = un("""INSERT INTO activite_sante (id_utilisateur, cle_externe, type, discipline,
                                               periode, duree_secondes, details)
                   VALUES (%s, 'MONTRE', 'running', 'course', tstzrange(%s, %s), 2400,
                           '{"appareil": "Watch"}') RETURNING id_activite""",
                u, debut, debut + timedelta(minutes=40))
    assert un("SELECT departager_activites_existantes()") == {"doublons": 1,
                                                              "seances_retirees": 0}
    assert un("SELECT id_occurrence FROM activite_sante WHERE id_activite = %s", montre) == seance


def test_une_seance_deja_saisie_n_est_pas_retiree(u):
    debut = _debut(30)
    strava = _ancienne(u, "STRAVA", debut, 40, "Strava")
    _ancienne(u, "MONTRE", debut + timedelta(seconds=20), 40, "Apple Watch", "Watch")
    seance = un("SELECT id_occurrence FROM activite_sante WHERE id_activite = %s", strava)
    sql("SELECT enregistrer_bilan(%s, %s, 6, 40, 'Bien', %s)", u, seance, uuid.uuid4())
    assert un("SELECT departager_activites_existantes()") == {"doublons": 1,
                                                              "seances_retirees": 0}
    assert un("SELECT count(*) FROM occurrence WHERE id_occurrence = %s", seance) == 1


def test_entre_deux_montres_la_premiere_recue_compte(u):
    debut = _debut(30)
    premiere = _ancienne(u, "M1", debut, 40, "Apple Watch", "Watch")
    seconde = _ancienne(u, "M2", debut + timedelta(seconds=30), 40, "Apple Watch", "Watch")
    un("SELECT departager_activites_existantes()")
    assert un("SELECT doublon_de FROM activite_sante WHERE id_activite = %s", seconde) == premiere
    assert un("SELECT doublon_de FROM activite_sante WHERE id_activite = %s", premiere) is None


# --- 3.22 à 3.25 : ce que l'appli lit ---------------------------------------------

def test_le_detail_d_une_course_nomme_ses_etapes(client, thomas, lorette, u):
    debut = _debut(5)
    cle = _seance(client, thomas, debut=debut, minutes=30)
    seance = un("SELECT id_occurrence FROM activite_sante WHERE cle_externe = %s", cle)
    # Échauffement lent, deux fractions rapides séparées d'une récupération, retour au calme.
    morceaux = [(0, 600, 2.6), (600, 700, 3.8), (700, 800, 2.4), (800, 900, 3.9), (900, 1800, 2.5)]
    points, segments = [], []
    for rang, (de, a, vitesse) in enumerate(morceaux, 1):
        segments.append({"sorte": "etape", "rang": rang,
                         "debut": (debut + timedelta(seconds=de)).isoformat(),
                         "fin": (debut + timedelta(seconds=a)).isoformat()})
        for t in range(de, a, 10):
            instant = (debut + timedelta(seconds=t)).isoformat()
            points += [{"grandeur": "vitesse", "debut": instant, "valeur": vitesse},
                       {"grandeur": "fc", "debut": instant, "valeur": 120 + 15 * vitesse}]
    client.put(f"/donnees-sante/activites/{cle}/series", headers=thomas, json={"series": points})
    client.put(f"/donnees-sante/activites/{cle}/segments", headers=thomas,
               json={"segments": segments})
    client.put(f"/donnees-sante/activites/{cle}/trace", headers=thomas, json={"points": [
        {"instant": (debut + timedelta(seconds=t)).isoformat(), "latitude": 48.69 + t / 1e5,
         "longitude": 6.18} for t in range(0, 1800, 2)]})

    rendu = client.get(f"/appli/seances/{seance}/course", headers=thomas)
    assert rendu.status_code == 200, rendu.text
    detail = rendu.json()
    assert [e["nom"] for e in detail["etapes"]] == [
        "Échauffement", "Fraction 1", "Récupération", "Fraction 2", "Retour au calme"]
    assert detail["etapes"][1]["allure_s_km"] == round(1000 / 3.8)
    assert len(detail["trace"]) <= 402 and detail["trace"][0]["etape"] == 1
    assert len(detail["zones"]) == 5 and sum(detail["zones"]) > 0
    assert detail["courbe"][0]["t"] == 0
    # Lorette ne voit pas la course de Thomas.
    assert client.get(f"/appli/seances/{seance}/course", headers=lorette).status_code == 404


def test_une_nuit_et_la_forme_se_lisent(client, thomas):
    lever = datetime.now(PARIS).replace(hour=7, minute=0, second=0, microsecond=0) \
        - timedelta(days=1)
    coucher = lever - timedelta(hours=7, minutes=30)
    phases, t = [], coucher
    for rang, (phase, minutes) in enumerate([("leger", 60), ("profond", 90), ("paradoxal", 60),
                                             ("leger", 210), ("eveille", 30)]):
        phases.append({"cle": f"N-{rang}", "phase": phase, "debut": t.isoformat(),
                       "fin": (t + timedelta(minutes=minutes)).isoformat(), "appareil": "Watch"})
        t += timedelta(minutes=minutes)
    client.put("/donnees-sante/sommeil", headers=thomas, json={"phases": phases})
    client.put("/donnees-sante/echantillons", headers=thomas, json={"echantillons": [
        {"cle": f"FC-{m}", "grandeur": "fc", "debut": (coucher + timedelta(minutes=m)).isoformat(),
         "valeur": 60 - (m // 60), "appareil": "Watch"} for m in range(0, 450, 10)] + [
        {"cle": "VO2", "grandeur": "vo2max", "debut": coucher.isoformat(), "valeur": 47.3,
         "appareil": "Watch"}]})

    nuit = client.get(f"/appli/sante/nuit?jour={lever.date().isoformat()}", headers=thomas)
    assert nuit.status_code == 200, nuit.text
    assert nuit.json()["minutes"] == {"leger": 270, "profond": 90, "paradoxal": 60, "eveille": 30}
    assert nuit.json()["fc_plus_basse"]["bpm"] == 53
    # Sans jour : la dernière nuit reçue.
    derniere = client.get("/appli/sante/nuit", headers=thomas).json()
    assert derniere["jour"] == lever.date().isoformat()
    assert client.get("/appli/sante/nuit?jour=2020-01-01", headers=thomas).status_code == 404

    forme = client.get("/appli/sante/forme?jours=30", headers=thomas).json()
    assert forme["vo2max"][0]["valeur"] == 47.3
    assert client.get("/appli/sante/forme?jours=0", headers=thomas).status_code == 200


# --- SAN-17 : ce que HAL lit d'une course -----------------------------------------

def _course_detaillee(client, entete, debut, morceaux, prevus=None):
    """Une course avec ses étapes : (début s, fin s, vitesse m/s) pour chacune."""
    cle = _seance(client, entete, debut=debut, minutes=morceaux[-1][1] // 60)
    points, segments = [], []
    for rang, (de, a, vitesse) in enumerate(morceaux, 1):
        segments.append({"sorte": "etape", "rang": rang, "prevu": (prevus or {}).get(rang),
                         "debut": (debut + timedelta(seconds=de)).isoformat(),
                         "fin": (debut + timedelta(seconds=a)).isoformat(),
                         "distance_m": round(vitesse * (a - de))})
        for t in range(de, a, 5):
            instant = (debut + timedelta(seconds=t)).isoformat()
            # La FC monte doucement à allure égale : 6 % sur la course.
            fc = 110 + 15 * vitesse + 9 * t / morceaux[-1][1]
            points += [{"grandeur": "vitesse", "debut": instant, "valeur": vitesse},
                       {"grandeur": "fc", "debut": instant, "valeur": round(fc)}]
    client.put(f"/donnees-sante/activites/{cle}/series", headers=entete, json={"series": points})
    client.put(f"/donnees-sante/activites/{cle}/segments", headers=entete,
               json={"segments": segments})
    client.put(f"/donnees-sante/activites/{cle}/trace", headers=entete, json={"points": [
        {"instant": debut.isoformat(), "latitude": 48.69, "longitude": 6.18}]})
    return un("SELECT id_occurrence FROM activite_sante WHERE cle_externe = %s", cle)


def test_hal_lit_une_course_etape_par_etape(client, thomas, u):
    from api.coach import outils
    objectif = {"distance_m": 400, "objectif_s": 100}
    seance = _course_detaillee(
        client, thomas, _debut(6),
        [(0, 600, 2.6), (600, 700, 4.0), (700, 790, 2.2), (790, 900, 3.7), (900, 1500, 2.5)],
        prevus={2: objectif, 4: objectif})
    lu = outils.lire_seance(u, {"id_occurrence": seance})
    course = lu["course_en_detail"]
    assert course["seance"].startswith("Fractionné 2 × 400 m")
    assert "1 tenues sur 2" in course["fractions"]
    assert "La dernière perd 10 s" in course["fractions"]
    assert "redescend" in course["fractions"]
    assert course["etapes"][1].startswith("Fraction 1 : 1:40") and "tenu" in course["etapes"][1]
    assert course["etapes"][3].endswith("+10 s)")
    # Le tracé ne part jamais au modèle, ni les mesures brutes.
    texte = str(lu)
    assert "48.69" not in texte and "latitude" not in texte and "frequence" not in texte


def test_hal_voit_la_derive_d_une_sortie_continue(client, thomas, u):
    from api.coach import outils
    _course_detaillee(client, thomas, _debut(30), [(0, 2400, 2.8)])
    lu = outils.lire_courses(u, {"detail": True})
    course = lu["courses"][0]
    assert course["seance"].startswith("Course continue")
    assert course["derive_cardiaque"].startswith("Dérive cardiaque +")
    assert "fractions" not in course
    assert outils.lire_courses(u, {"du": "2020-01-01", "au": "2020-01-02"})["courses"] \
        .startswith("Aucune course")
    refus = outils.executer_outil("lire_courses", u, {"du": "2020-01-01"}, {"lire_courses"})
    assert refus[1] is True and "90 jours" in refus[0]


def test_la_revision_lit_les_dernieres_courses(client, thomas, u):
    from api.coach import office
    _course_detaillee(client, thomas, _debut(30), [(0, 2400, 2.8)])
    assert "## Les dernières courses, étape par étape (lire_courses)" in office.texte(u, "revision")
