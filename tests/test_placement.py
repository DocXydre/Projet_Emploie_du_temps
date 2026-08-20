"""Répartition, anticipation et stabilité du planning.

Trois défauts constatés à l'usage, sur de vraies données :
les tâches s'entassaient toutes sur la première journée libre, le planning ne
tenait que trois semaines, et il changeait à chaque recalcul.
"""

from collections import Counter
from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo

import psycopg

from tests.conftest import _url

PARIS = ZoneInfo("Europe/Paris")


def jours_des_rappels(client, thomas) -> Counter:
    """Combien de rappels par journée civile française.

    La conversion compte : l'API renvoie de l'UTC, et un rappel du 21 août à
    Paris s'y écrit « 20 août 22:00 ». Comparer les dates sans convertir
    décalerait tout d'un jour.
    """
    # Filtré sur l'appelant : le pliage du linge revient à Lorette, dont les
    # journées sont libres. Sans ce filtre, on mesurerait la charge de deux
    # personnes à la fois.
    moi = client.get("/moi", headers=thomas).json()["id_utilisateur"]
    planning = client.get("/planning", headers=thomas, params={
        "utilisateur": moi,
        "fin": (datetime.now(UTC) + timedelta(days=40)).isoformat(),
    }).json()
    return Counter(
        datetime.fromisoformat(ligne["debut"]).astimezone(PARIS).date().isoformat()
        for ligne in planning
        if ligne["nature"] == "tache" and ligne["journee_entiere"]
    )


# ---------------------------------------------------------------------------
# Répartition
# ---------------------------------------------------------------------------

def test_les_taches_ne_s_entassent_plus_sur_un_seul_jour(client, thomas):
    client.post("/planning/placer", headers=thomas)

    par_jour = jours_des_rappels(client, thomas)
    assert par_jour, "aucun rappel placé"

    # Avant, les sept rappels tombaient tous le même jour. La fenêtre
    # d'échéance existe précisément pour offrir cette marge.
    assert len(par_jour) >= 3, f"répartis sur {len(par_jour)} jour(s) : {par_jour}"
    assert max(par_jour.values()) <= 3, f"une journée trop chargée : {par_jour}"


def test_une_journee_saturee_ne_recoit_aucune_tache(client, thomas):
    # Journée civile française entièrement occupée : rien ne peut y tenir,
    # même une litière de cinq minutes.
    minuit = datetime.now(PARIS).replace(hour=0, minute=0, second=0, microsecond=0)
    client.post("/occupations", headers=thomas, json={
        "type": "cours", "libelle": "Journée saturée",
        "debut": minuit.isoformat(),
        "fin": (minuit + timedelta(days=1)).isoformat(),
    })

    client.post("/planning/placer", headers=thomas)

    par_jour = jours_des_rappels(client, thomas)
    assert par_jour.get(minuit.date().isoformat(), 0) == 0

    # Et les tâches à fenêtre courte se reportent sur le lendemain plutôt que
    # de rester sans créneau.
    lendemain = (minuit + timedelta(days=1)).date().isoformat()
    assert par_jour.get(lendemain, 0) >= 1


# ---------------------------------------------------------------------------
# Anticipation
# ---------------------------------------------------------------------------

def test_le_planning_couvre_un_mois(client, thomas):
    client.post("/planning/placer", headers=thomas)

    par_jour = jours_des_rappels(client, thomas)
    dernier = max(par_jour)
    limite = (datetime.now(UTC) + timedelta(days=20)).date().isoformat()

    # Les tâches fréquentes doivent revenir plusieurs fois sur l'horizon.
    assert dernier > limite, f"le planning s'arrête au {dernier}"


def test_une_tache_frequente_revient_plusieurs_fois(client, thomas):
    client.post("/planning/placer", headers=thomas)

    toutes = client.get("/occurrences", headers=thomas,
                        params={"statut": ["a_placer", "planifiee"]}).json()
    aspirateurs = [o for o in toutes if o["tache_code"] == "ASPIRATEUR"]

    # Tous les 2 à 3 jours sur 35 jours : une dizaine d'occurrences.
    assert len(aspirateurs) >= 8, f"seulement {len(aspirateurs)} occurrence(s)"


def test_valider_efface_les_previsions_devenues_fausses(client, thomas):
    client.post("/planning/placer", headers=thomas)

    toutes = client.get("/occurrences", headers=thomas,
                        params={"statut": ["a_placer", "planifiee"]}).json()
    aspirateurs = sorted([o for o in toutes if o["tache_code"] == "ASPIRATEUR"],
                         key=lambda o: o["echeance_min"])
    avant = len(aspirateurs)
    assert avant >= 3

    client.post(f"/occurrences/{aspirateurs[0]['id_occurrence']}/valider",
                headers=thomas, json={})

    restantes = client.get("/occurrences", headers=thomas,
                           params={"statut": ["a_placer", "planifiee"]}).json()
    apres = [o for o in restantes if o["tache_code"] == "ASPIRATEUR"]

    # Les prévisions supposaient une exécution en fin de fenêtre. La validation
    # dit quand la tâche a vraiment été faite : la suite est à refaire.
    assert len(apres) == 1

    # La suivante repart de la date réelle d'exécution — aujourd'hui — et non
    # de la fin de la fenêtre qui vient d'être soldée.
    faite = client.get(f"/occurrences/{aspirateurs[0]['id_occurrence']}",
                       headers=thomas).json()
    debut = datetime.fromisoformat(apres[0]["echeance_min"])
    assert debut >= datetime.fromisoformat(faite["date_faite"]) + timedelta(days=1)


def test_la_chaine_se_reconstitue_au_placement_suivant(client, thomas):
    client.post("/planning/placer", headers=thomas)
    toutes = client.get("/occurrences", headers=thomas,
                        params={"statut": ["a_placer", "planifiee"]}).json()
    aspirateur = next(o for o in toutes if o["tache_code"] == "ASPIRATEUR")

    client.post(f"/occurrences/{aspirateur['id_occurrence']}/valider",
                headers=thomas, json={})
    client.post("/planning/placer", headers=thomas)

    restantes = client.get("/occurrences", headers=thomas,
                           params={"statut": ["a_placer", "planifiee"]}).json()
    apres = [o for o in restantes if o["tache_code"] == "ASPIRATEUR"]
    assert len(apres) >= 8


# ---------------------------------------------------------------------------
# Stabilité
# ---------------------------------------------------------------------------

def creneaux(client, thomas) -> dict[int, str]:
    moi = client.get("/moi", headers=thomas).json()["id_utilisateur"]
    toutes = client.get("/occurrences", headers=thomas,
                        params={"statut": ["planifiee", "notifiee"], "assigne": moi}).json()
    return {o["id_occurrence"]: o["debut"] for o in toutes if o["debut"]}


def test_ce_qui_est_prevu_cette_semaine_ne_bouge_plus(client, thomas):
    client.post("/planning/placer", headers=thomas)
    avant = creneaux(client, thomas)

    limite = datetime.now(UTC) + timedelta(days=7)
    proches = {i: d for i, d in avant.items() if datetime.fromisoformat(d) <= limite}
    assert proches, "rien de prévu dans les sept jours"

    # Un nouveau shift bouscule le planning : les jours lointains peuvent
    # bouger, la semaine en cours non.
    demain = datetime.now(UTC) + timedelta(days=1)
    client.post("/occupations", headers=thomas, json={
        "type": "travail", "libelle": "Shift ajouté",
        "debut": demain.replace(hour=9, minute=0, second=0, microsecond=0).isoformat(),
        "fin": demain.replace(hour=22, minute=0, second=0, microsecond=0).isoformat(),
    })
    client.post("/planning/placer", headers=thomas)

    apres = creneaux(client, thomas)
    for identifiant, debut in proches.items():
        assert apres.get(identifiant) == debut, \
            f"l'occurrence {identifiant} a bougé alors qu'elle est proche"


def test_le_lointain_peut_encore_etre_reorganise(client, thomas):
    client.post("/planning/placer", headers=thomas)
    avant = creneaux(client, thomas)

    # Une occurrence prévue au-delà de la semaine figée.
    limite = datetime.now(UTC) + timedelta(days=10)
    lointaines = {i: d for i, d in avant.items()
                  if datetime.fromisoformat(d) > limite}
    assert lointaines, "rien de prévu au-delà de dix jours"

    identifiant, jour = next(iter(lointaines.items()))

    # On occupe entièrement ce jour-là : la tâche doit trouver ailleurs.
    debut = datetime.fromisoformat(jour)
    client.post("/occupations", headers=thomas, json={
        "type": "cours", "libelle": "Journée bloquée",
        "debut": debut.isoformat(),
        "fin": (debut + timedelta(days=1)).isoformat(),
    })
    client.post("/planning/placer", headers=thomas)

    apres = creneaux(client, thomas)
    assert apres.get(identifiant) != jour, \
        "une occurrence lointaine doit pouvoir être réorganisée"


def test_une_occurrence_notifiee_ne_bouge_jamais(client, thomas):
    client.post("/planning/placer", headers=thomas)
    client.post("/notifications/bilan", headers=thomas)

    moi = client.get("/moi", headers=thomas).json()["id_utilisateur"]
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row) as conn:
        notifiees = conn.execute(
            "SELECT id_occurrence, lower(creneau) AS debut FROM occurrence "
            "WHERE statut = 'notifiee' AND id_utilisateur = %s",
            (moi,),
        ).fetchall()

    client.post("/planning/placer", headers=thomas, params={"stabilite_jours": 0})

    apres = creneaux(client, thomas)
    for ligne in notifiees:
        assert apres[ligne["id_occurrence"]] == ligne["debut"].isoformat()
