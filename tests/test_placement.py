"""Répartition, anticipation et stabilité du planning.

Trois défauts constatés à l'usage, sur de vraies données :
les tâches s'entassaient toutes sur la première journée libre, le planning ne
tenait que trois semaines, et il changeait à chaque recalcul.
"""

from collections import Counter
from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo

import psycopg

from tests.conftest import _url, id_de

PARIS = ZoneInfo("Europe/Paris")


def jours_des_rappels(client, thomas, tout_le_monde: bool = False) -> Counter:
    """Combien de rappels par journée civile française.

    La conversion compte : l'API renvoie de l'UTC, et un rappel du 21 août à
    Paris s'y écrit « 20 août 22:00 ». Comparer les dates sans convertir
    décalerait tout d'un jour.
    """
    # Filtré sur l'appelant : le pliage du linge revient à Lorette, dont les
    # journées sont libres. Sans ce filtre, on mesurerait la charge de deux
    # personnes à la fois.
    parametres = {"fin": (datetime.now(UTC) + timedelta(days=40)).isoformat()}
    if not tout_le_monde:
        parametres["utilisateur"] = client.get(
            "/moi", headers=thomas).json()["id_utilisateur"]
    planning = client.get("/planning", headers=thomas, params=parametres).json()
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
    # de rester sans créneau. On compte ici les deux personnes : depuis le
    # roulement (PLA-12), la tâche repoussée peut revenir à l'une ou à l'autre,
    # et la question posée ici est qu'elle trouve un jour, pas qui la fait.
    lendemain = (minuit + timedelta(days=1)).date().isoformat()
    assert jours_des_rappels(client, thomas, tout_le_monde=True).get(lendemain, 0) >= 1


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
    aspirateurs = [o for o in toutes if o["id_tache"] == id_de("ASPIRATEUR")]

    # Tous les 2 à 3 jours sur 35 jours : une dizaine d'occurrences.
    assert len(aspirateurs) >= 8, f"seulement {len(aspirateurs)} occurrence(s)"


def test_la_validation_repositionne_la_tache_enchainee(client, thomas):
    """EXE-2 : une tâche enchaînée déjà en attente est repositionnée, pas doublée.

    Le lave-vaisselle lancé deux soirs de suite ne donne pas deux vidages : celui
    qui attendait est recalé après le second lancement.

    On valide en SQL et non par l'API : la validation par l'API replace le
    planning dans la foulée (EXE-15), et le placement efface le motif en posant
    le créneau. C'est bien le motif qu'on veut lire ici.
    """
    client.post("/planning/placer", headers=thomas)
    moi = client.get("/moi", headers=thomas).json()["id_utilisateur"]

    with psycopg.connect(_url(), autocommit=True) as conn:
        def lancer() -> None:
            numero = conn.execute(
                "SELECT o.id_occurrence FROM occurrence o JOIN tache t USING (id_tache) "
                " WHERE t.id_tache = essais.tache_de('LAVE_VAISSELLE')"
                " AND o.statut IN ('a_placer', 'planifiee') "
                " ORDER BY lower(o.fenetre) LIMIT 1").fetchone()[0]
            conn.execute("SELECT valider_occurrence(%s, %s, NULL)", (numero, moi))

        def vidages() -> list[str]:
            return [ligne[0] for ligne in conn.execute(
                "SELECT COALESCE(o.motif, '') FROM occurrence o JOIN tache t USING (id_tache) "
                " WHERE t.id_tache = essais.tache_de('VIDER_LAVE_VAISSELLE')"
                "   AND o.statut = 'a_placer'")]

        lancer()
        assert len(vidages()) == 1
        lancer()
        apres = vidages()

    assert len(apres) == 1
    assert apres[0].startswith("Repositionnée")


def test_valider_efface_les_previsions_devenues_fausses(client, thomas):
    client.post("/planning/placer", headers=thomas)

    toutes = client.get("/occurrences", headers=thomas,
                        params={"statut": ["a_placer", "planifiee"]}).json()
    aspirateurs = sorted([o for o in toutes if o["id_tache"] == id_de("ASPIRATEUR")],
                         key=lambda o: o["echeance_min"])
    avant = len(aspirateurs)
    assert avant >= 3

    client.post(f"/occurrences/{aspirateurs[0]['id_occurrence']}/valider",
                headers=thomas, json={})

    restantes = client.get("/occurrences", headers=thomas,
                           params={"statut": ["a_placer", "planifiee"]}).json()
    apres = [o for o in restantes if o["id_tache"] == id_de("ASPIRATEUR")]

    # Les prévisions supposaient une exécution en fin de fenêtre. La validation
    # dit quand la tâche a vraiment été faite : la suite est refaite, et elle
    # repart toute entière de la date réelle (EXE-15 replace dans la foulée,
    # d'où une chaîne reconstruite et non une occurrence isolée).
    faite = client.get(f"/occurrences/{aspirateurs[0]['id_occurrence']}",
                       headers=thomas).json()
    reelle = datetime.fromisoformat(faite["date_faite"])

    # TAC-15 : un récurage ou une poussière le lendemain peut poser un
    # aspirateur de plus, faute d'en avoir un à portée. Il accompagne une
    # autre tâche et porte son titre : ce n'est pas une prévision de la chaîne.
    with psycopg.connect(_url()) as conn:
        accompagnent = {i for (i,) in conn.execute(
            "SELECT id_occurrence FROM occurrence WHERE titre IS NOT NULL").fetchall()}
    chaine = [o for o in apres if o["id_occurrence"] not in accompagnent]

    assert chaine
    for occurrence in chaine:
        debut = datetime.fromisoformat(occurrence["echeance_min"])
        assert debut >= reelle + timedelta(days=1), occurrence


def test_la_chaine_se_reconstitue_au_placement_suivant(client, thomas):
    client.post("/planning/placer", headers=thomas)
    toutes = client.get("/occurrences", headers=thomas,
                        params={"statut": ["a_placer", "planifiee"]}).json()
    aspirateur = next(o for o in toutes if o["id_tache"] == id_de("ASPIRATEUR"))

    client.post(f"/occurrences/{aspirateur['id_occurrence']}/valider",
                headers=thomas, json={})
    client.post("/planning/placer", headers=thomas)

    restantes = client.get("/occurrences", headers=thomas,
                           params={"statut": ["a_placer", "planifiee"]}).json()
    apres = [o for o in restantes if o["id_tache"] == id_de("ASPIRATEUR")]
    assert len(apres) >= 8


# ---------------------------------------------------------------------------
# Stabilité
# ---------------------------------------------------------------------------

def creneaux(client, thomas) -> dict[int, str]:
    """Ce que le placement a posé, hors réservations de sport.

    Une séance « à déterminer » n'est pas une tâche placée : elle tient une
    place tant que le jour reste praticable, et s'efface dès qu'un cours ou un
    service le prend (SPT-23). La juger à l'aune de la stabilité du placement
    ferait échouer ces tests un jour sur sept, selon le jour où elle tombe.
    """
    moi = client.get("/moi", headers=thomas).json()["id_utilisateur"]
    toutes = client.get("/occurrences", headers=thomas,
                        params={"statut": ["planifiee", "notifiee"], "assigne": moi}).json()
    return {o["id_occurrence"]: o["debut"] for o in toutes
            if o["debut"] and o["origine"] != "quota"}


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
            " WHERE statut = 'notifiee' AND id_utilisateur = %s "
            # Comme au-dessus : une réservation de sport ne relève pas de la
            # stabilité du placement.
            "   AND origine <> 'quota'",
            (moi,),
        ).fetchall()

    # Sans tâche annoncée, la boucle ne vérifierait rien et le test passerait.
    assert notifiees, "le bilan du matin n'a rien annoncé"

    client.post("/planning/placer", headers=thomas, params={"stabilite_jours": 0})

    apres = creneaux(client, thomas)
    for ligne in notifiees:
        # On compare des instants, pas des écritures : l'API rend « Z » là où
        # Python écrit « +00:00 », et le test échouait sur la forme.
        assert datetime.fromisoformat(apres[ligne["id_occurrence"]]) == ligne["debut"]
