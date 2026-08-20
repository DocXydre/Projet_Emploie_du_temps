"""Absence : on ne fait pas le ménage d'un appartement où l'on n'est pas.

Et surtout, on ne le salit pas. Partir trois jours à Saint-Dié ne doit pas
produire trois jours de retard au retour.
"""

from collections import Counter
from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo

import psycopg

from api import conversation as conv
from tests.conftest import CLE_LORETTE, CLE_THOMAS, _url

PARIS = ZoneInfo("Europe/Paris")


def identifiant(client, cle: str) -> int:
    return client.get("/moi", headers={"X-Cle-Api": cle}).json()["id_utilisateur"]


def minuit(dans_jours: int) -> datetime:
    return (datetime.now(PARIS) + timedelta(days=dans_jours)).replace(
        hour=0, minute=0, second=0, microsecond=0)


def declarer(client, entetes, debut_j: int, fin_j: int, lieu: str = "Saint-Dié") -> dict:
    reponse = client.post("/absences", headers=entetes, json={
        "debut": minuit(debut_j).isoformat(),
        "fin": minuit(fin_j).isoformat(),
        "lieu": lieu,
    })
    assert reponse.status_code == 201, reponse.text
    return reponse.json()


def jours_charges(client, entetes, cle: str) -> Counter:
    moi = identifiant(client, cle)
    planning = client.get("/planning", headers=entetes, params={
        "utilisateur": moi,
        "fin": (datetime.now(UTC) + timedelta(days=30)).isoformat(),
    }).json()
    return Counter(
        datetime.fromisoformat(ligne["debut"]).astimezone(PARIS).date().isoformat()
        for ligne in planning
        if ligne["nature"] == "tache" and ligne["journee_entiere"]
    )


# ---------------------------------------------------------------------------
# Déclaration
# ---------------------------------------------------------------------------

def test_declarer_une_absence(client, thomas):
    creee = declarer(client, thomas, 3, 6)
    assert creee["lieu"] == "Saint-Dié"

    absences = client.get("/absences", headers=thomas).json()
    assert len(absences) == 1
    assert absences[0]["pseudo"] == "thomas"
    assert absences[0]["origine"] == "manuelle"


def test_deux_absences_ne_peuvent_pas_se_chevaucher(client, thomas):
    declarer(client, thomas, 3, 6)

    reponse = client.post("/absences", headers=thomas, json={
        "debut": minuit(5).isoformat(), "fin": minuit(8).isoformat(),
    })
    assert reponse.status_code == 409
    assert reponse.json()["code"] == "chevauchement"


def test_une_periode_a_l_envers_est_refusee(client, thomas):
    reponse = client.post("/absences", headers=thomas, json={
        "debut": minuit(6).isoformat(), "fin": minuit(3).isoformat(),
    })
    assert reponse.status_code == 400


def test_annuler_une_absence(client, thomas):
    creee = declarer(client, thomas, 3, 6)
    assert client.delete(f"/absences/{creee['id_absence']}",
                         headers=thomas).status_code == 204
    assert client.get("/absences", headers=thomas).json() == []


# ---------------------------------------------------------------------------
# Effet sur le planning
# ---------------------------------------------------------------------------

def test_aucune_tache_pendant_l_absence(client, thomas):
    declarer(client, thomas, 3, 6)
    client.post("/planning/placer", headers=thomas)

    par_jour = jours_charges(client, thomas, CLE_THOMAS)
    for decalage in (3, 4, 5):
        jour = minuit(decalage).date().isoformat()
        assert par_jour.get(jour, 0) == 0, f"une tâche est prévue le {jour}"


def test_le_jour_du_depart_reste_utilisable(client, thomas):
    # Partir en fin de journée ne dispense pas de la journée : la tâche peut
    # être faite avant de prendre le train.
    depart = datetime.now(PARIS) + timedelta(days=3)
    client.post("/absences", headers=thomas, json={
        "debut": depart.replace(hour=19, minute=0, second=0, microsecond=0).isoformat(),
        "fin": minuit(6).isoformat(),
    })

    moi = identifiant(client, CLE_THOMAS)
    with psycopg.connect(_url()) as conn:
        absent = conn.execute("SELECT est_absent(%s, %s)",
                              (moi, depart.date())).fetchone()[0]
    assert absent is False


def test_les_taches_reviennent_apres_le_retour(client, thomas):
    declarer(client, thomas, 3, 6)
    client.post("/planning/placer", headers=thomas)

    par_jour = jours_charges(client, thomas, CLE_THOMAS)
    apres = [j for j in par_jour if j >= minuit(6).date().isoformat()]
    assert apres, "aucune tâche après le retour"


def test_partir_ne_cree_pas_de_retard(client, thomas):
    declarer(client, thomas, 1, 5)
    client.post("/planning/placer", headers=thomas)

    # Aucune occurrence ne doit rester sans créneau du seul fait de l'absence :
    # elles se replacent avant le départ ou après le retour.
    sans_creneau = [o for o in client.get("/occurrences", headers=thomas,
                                          params={"statut": ["a_placer"]}).json()
                    if o["motif"] and "Personne dans l'appartement" in o["motif"]]
    assert sans_creneau == []


# ---------------------------------------------------------------------------
# Répartition à deux
# ---------------------------------------------------------------------------

def test_l_autre_reprend_les_taches_pendant_l_absence(client, thomas, lorette):
    declarer(client, thomas, 2, 9)
    client.post("/planning/placer", headers=thomas)

    lorette_id = identifiant(client, CLE_LORETTE)
    par_jour = jours_charges(client, lorette, CLE_LORETTE)

    # Pendant l'absence de Thomas, c'est Lorette qui a les tâches domestiques.
    pendant = [j for j in par_jour
               if minuit(2).date().isoformat() <= j < minuit(9).date().isoformat()]
    assert pendant, "Lorette devrait hériter des tâches"

    occurrences = client.get("/occurrences", headers=thomas,
                             params={"statut": ["planifiee"], "assigne": lorette_id}).json()
    assert occurrences


def test_la_repartition_se_mesure_en_minutes(client, thomas):
    # Les deux présents : la charge doit être comparable, pas le simple nombre
    # de tâches — récurer ne vaut pas ramasser la litière.
    client.post("/planning/placer", headers=thomas)

    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row) as conn:
        charges = conn.execute(
            """
            SELECT u.pseudo, COALESCE(sum(t.duree_minutes), 0) AS minutes
              FROM utilisateur u
              LEFT JOIN occurrence o ON o.id_utilisateur = u.id_utilisateur
                                    AND o.statut IN ('a_placer', 'planifiee', 'notifiee')
              LEFT JOIN tache t ON t.id_tache = o.id_tache
             WHERE u.actif
             GROUP BY u.pseudo
            """
        ).fetchall()

    minutes = {c["pseudo"]: c["minutes"] for c in charges}
    assert len(minutes) == 2

    total = sum(minutes.values())
    assert total > 0
    # Aucun des deux ne doit porter la quasi-totalité de la charge.
    assert max(minutes.values()) < total * 0.9, minutes


def test_appartement_vide_les_taches_attendent(client, thomas, lorette):
    declarer(client, thomas, 2, 5)
    declarer(client, lorette, 2, 5)

    client.post("/planning/placer", headers=thomas)

    with psycopg.connect(_url()) as conn:
        vide = conn.execute("SELECT appartement_vide(%s)",
                            (minuit(3).date(),)).fetchone()[0]
    assert vide is True

    par_jour_t = jours_charges(client, thomas, CLE_THOMAS)
    par_jour_l = jours_charges(client, lorette, CLE_LORETTE)
    for decalage in (2, 3, 4):
        jour = minuit(decalage).date().isoformat()
        assert par_jour_t.get(jour, 0) == 0
        assert par_jour_l.get(jour, 0) == 0


def test_le_pliage_reste_a_lorette_meme_absente(client, thomas, lorette):
    # Une assignation fixée ne se réattribue pas : le pliage revient à Lorette
    # même quand elle n'est pas là, elle le fera à son retour.
    declarer(client, lorette, 2, 5)

    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row) as conn:
        tache = conn.execute(
            "SELECT id_tache, id_utilisateur_defaut FROM tache WHERE code = 'PLIER_LINGE'"
        ).fetchone()
        assigne = conn.execute(
            "SELECT choisir_assigne(%s, tstzrange(now(), now() + INTERVAL '7 days')) AS qui",
            (tache["id_tache"],),
        ).fetchone()["qui"]

    assert assigne == tache["id_utilisateur_defaut"]


# ---------------------------------------------------------------------------
# Lecture des dates par le bot
# ---------------------------------------------------------------------------

def test_le_bot_lit_une_periode():
    periode = conv.lire_periode(["22/08", "24/08"])
    assert periode is not None
    debut, fin = periode
    assert debut.day == 22 and debut.month == 8
    # La fin est exclusive : le 24 est inclus dans l'absence.
    assert fin.day == 25


def test_le_bot_accepte_une_seule_date():
    periode = conv.lire_periode(["22/08"])
    assert periode is not None
    debut, fin = periode
    assert (fin - debut).days == 1


def test_le_bot_refuse_ce_qu_il_ne_comprend_pas():
    assert conv.lire_periode(["ce", "week-end"]) is None
    assert conv.lire_periode(["32/13"]) is None
    assert conv.lire_periode([]) is None


def test_la_presence_est_lisible_jour_par_jour(client, thomas):
    declarer(client, thomas, 2, 5)
    presence = client.get("/absences/presence", headers=thomas, params={"jours": 7}).json()

    assert len(presence) == 8
    absent = next(p for p in presence if p["jour"] == minuit(3).date().isoformat())
    moi = identifiant(client, CLE_THOMAS)
    assert moi not in absent["presents"]
