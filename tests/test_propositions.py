"""Propositions de week-end : le système parle sans qu'on le lui demande.

Il savait déjà repérer un creux de deux jours, mais ne le disait que sur
demande — ce qui suppose d'y penser, et si l'on y pensait on n'aurait pas
besoin du système.

Deux choses se vérifient ici. Qu'une proposition ne gèle rien : confondre une
suggestion et une absence bloquerait le ménage sur un simple « et si ». Et
qu'on ne répète pas : deux annonces valent un service, dix valent des
notifications coupées.
"""

from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import psycopg
from icalendar import Calendar

from api import propositions
from tests.conftest import JETON_THOMAS, _url

PARIS = ZoneInfo("Europe/Paris")


def _minuit(dans_jours: int) -> datetime:
    return (datetime.now(PARIS) + timedelta(days=dans_jours)).replace(
        hour=0, minute=0, second=0, microsecond=0)


def _occuper(client, entete, jours: set[int], fin_veille=(17, 35)) -> None:
    """Remplit l'horizon sauf les jours voulus : un creux n'existe que par contraste."""
    for jour in range(0, 26):
        if jour in jours:
            continue
        fin = _minuit(jour).replace(hour=20)
        if jour + 1 in jours:
            fin = _minuit(jour).replace(hour=fin_veille[0], minute=fin_veille[1])
        client.post("/occupations", headers=entete, json={
            "type": "cours", "libelle": f"Cours J+{jour}",
            "debut": _minuit(jour).replace(hour=8).isoformat(),
            "fin": fin.isoformat(),
        })


def notifications() -> list[dict]:
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row) as conn:
        return conn.execute(
            "SELECT type, contenu, id_proposition FROM notification "
            " WHERE id_proposition IS NOT NULL ORDER BY id_notification").fetchall()


# ---------------------------------------------------------------------------
# Repérage
# ---------------------------------------------------------------------------

def test_un_week_end_a_deux_semaines_est_propose(client, thomas):
    _occuper(client, thomas, {12, 13})

    trouvees = propositions.reperer(1)

    assert len(trouvees) == 1
    assert trouvees[0]["lieu"] == "Lusse"
    assert trouvees[0]["debut"].astimezone(PARIS).hour == 17


def test_un_week_end_trop_lointain_attend_son_tour(client, thomas):
    # Vingt jours : le repérage se fait à quinze, pas au-delà. Annoncer trop
    # tôt ne sert à rien — l'emploi du temps n'est pas encore sûr.
    _occuper(client, thomas, {20, 21})
    assert propositions.reperer(1) == []


def test_une_fenetre_a_cheval_sur_le_delai_est_vue_entiere(client, thomas):
    # Un creux qui commence dans treize jours et finit dans seize serait
    # tronqué par l'horizon, et passerait sous les quarante-huit heures pour
    # une raison qui n'a rien à voir avec l'emploi du temps.
    _occuper(client, thomas, {13, 14, 15})

    trouvees = propositions.reperer(1)
    assert len(trouvees) == 1
    assert trouvees[0]["fin"] - trouvees[0]["debut"] > timedelta(hours=72)


def test_reperer_deux_fois_ne_double_pas(client, thomas):
    _occuper(client, thomas, {12, 13})
    propositions.reperer(1)

    # R87 : rejouée le lendemain, la ronde ne doit rien créer de neuf.
    assert propositions.reperer(1) == []
    assert len(propositions.en_attente(1)) == 1


def test_un_week_end_deja_couvert_par_une_absence_n_est_pas_propose(client, thomas):
    _occuper(client, thomas, {12, 13})
    client.post("/absences", headers=thomas, json={
        "debut": _minuit(12).isoformat(),
        "fin": _minuit(14).isoformat(),
    })

    assert propositions.reperer(1) == []


def test_acheter_le_billet_solde_la_proposition(client, thomas):
    _occuper(client, thomas, {12, 13})
    propositions.reperer(1)

    client.post("/absences", headers=thomas, json={
        "debut": _minuit(12).isoformat(),
        "fin": _minuit(14).isoformat(),
        "lieu": "Lusse",
    })
    propositions.tour_de_ronde(1)

    # La question ne se pose plus : on est parti.
    assert propositions.en_attente(1) == []


# ---------------------------------------------------------------------------
# Annonce et relance
# ---------------------------------------------------------------------------

def test_la_ronde_annonce_une_fois(client, thomas):
    _occuper(client, thomas, {12, 13})

    bilan = propositions.tour_de_ronde(1)
    assert bilan == {"proposees": 1, "relancees": 0}

    envoyees = notifications()
    assert len(envoyees) == 1
    assert "Week-end libre repéré" in envoyees[0]["contenu"]
    assert "Lusse" in envoyees[0]["contenu"]


def test_la_ronde_du_lendemain_se_tait(client, thomas):
    _occuper(client, thomas, {12, 13})
    propositions.tour_de_ronde(1)

    assert propositions.tour_de_ronde(1) == {"proposees": 0, "relancees": 0}
    assert len(notifications()) == 1


def _hier(champ: str = "annoncee_le") -> None:
    """Fait comme si l'annonce datait de la veille."""
    with psycopg.connect(_url(), autocommit=True) as conn:
        conn.execute(f"UPDATE proposition SET {champ} = now() - INTERVAL '1 day'")


def test_pas_de_relance_le_jour_de_l_annonce(client, thomas):
    _occuper(client, thomas, {2, 3})

    # Annoncer puis relancer dans la même minute n'est pas un rappel, c'est
    # un bégaiement.
    assert propositions.tour_de_ronde(1) == {"proposees": 1, "relancees": 0}
    assert len(notifications()) == 1


def test_la_relance_arrive_a_trois_jours(client, thomas):
    _occuper(client, thomas, {2, 3})
    propositions.tour_de_ronde(1)
    _hier()

    seconde = propositions.tour_de_ronde(1)
    assert seconde["relancees"] == 1

    envoyees = notifications()
    assert len(envoyees) == 2
    assert "Ça approche" in envoyees[1]["contenu"]


def test_pas_de_relance_pour_un_week_end_encore_loin(client, thomas):
    _occuper(client, thomas, {12, 13})
    propositions.tour_de_ronde(1)
    _hier()

    # Douze jours : la relance est faite pour les trois derniers.
    assert propositions.tour_de_ronde(1)["relancees"] == 0


def test_on_ne_relance_qu_une_fois(client, thomas):
    _occuper(client, thomas, {2, 3})
    propositions.tour_de_ronde(1)
    _hier()
    propositions.tour_de_ronde(1)

    # R90 : répéter chaque jour transformerait un service en harcèlement, et
    # la réponse serait de couper les notifications.
    assert propositions.tour_de_ronde(1)["relancees"] == 0
    assert len(notifications()) == 2


def test_un_week_end_decline_ne_revient_pas(client, thomas):
    _occuper(client, thomas, {2, 3})
    propositions.tour_de_ronde(1)
    proposee = propositions.en_attente(1)[0]

    propositions.ecarter(proposee["id_proposition"])
    _hier()

    # R89 : ni nouvelle proposition, ni relance.
    assert propositions.tour_de_ronde(1) == {"proposees": 0, "relancees": 0}
    assert propositions.en_attente(1) == []


def test_decliner_deux_fois_ne_fait_rien(client, thomas):
    _occuper(client, thomas, {12, 13})
    propositions.reperer(1)
    identifiant = propositions.en_attente(1)[0]["id_proposition"]

    assert propositions.ecarter(identifiant) is not None
    assert propositions.ecarter(identifiant) is None


# ---------------------------------------------------------------------------
# Ce que ça ne fait pas
# ---------------------------------------------------------------------------

def test_une_proposition_ne_gele_aucune_tache(client, thomas):
    _occuper(client, thomas, {12, 13})
    propositions.tour_de_ronde(1)
    client.post("/planning/placer", headers=thomas)

    presence = client.get("/absences/presence", headers=thomas,
                          params={"jours": 20}).json()
    jour = next(p for p in presence if p["jour"] == _minuit(12).date().isoformat())

    # Confondre une suggestion et une absence bloquerait le ménage sur un
    # simple « et si ».
    assert 1 in jour["presents"]
    assert client.get("/absences", headers=thomas).json() == []


# ---------------------------------------------------------------------------
# Au calendrier
# ---------------------------------------------------------------------------

def test_la_proposition_apparait_au_calendrier(client, thomas):
    _occuper(client, thomas, {12, 13})
    propositions.reperer(1)

    flux = client.get("/planning.ics", params={"cle": JETON_THOMAS})
    calendrier = Calendar.from_ical(flux.content)
    evenements = [e for e in calendrier.walk("VEVENT")
                  if "Week-end libre" in str(e["SUMMARY"])]

    assert len(evenements) == 1
    assert "Proposition" in str(evenements[0]["SUMMARY"])
    assert "Lusse" in str(evenements[0]["SUMMARY"])


def test_elle_couvre_toute_la_periode_et_non_un_seul_jour(client, thomas):
    _occuper(client, thomas, {12, 13})
    propositions.reperer(1)

    flux = client.get("/planning.ics", params={"cle": JETON_THOMAS})
    calendrier = Calendar.from_ical(flux.content)
    evenement = next(e for e in calendrier.walk("VEVENT")
                     if "Week-end libre" in str(e["SUMMARY"]))

    # Un rappel tient sur une journée, une proposition sur trois. La borne de
    # fin d'un événement journée entière est exclusive.
    debut = evenement["DTSTART"].dt
    fin = evenement["DTEND"].dt
    assert evenement["DTSTART"].params.get("VALUE") == "DATE"
    assert (fin - debut).days >= 2


def test_un_rappel_tient_toujours_sur_une_seule_journee(client, thomas):
    client.post("/planning/placer", headers=thomas)
    from tests.test_boucle_quotidienne import forcer_au_jour_meme

    forcer_au_jour_meme("ASPIRATEUR")
    flux = client.get("/planning.ics", params={"cle": JETON_THOMAS})
    calendrier = Calendar.from_ical(flux.content)

    rappels = [e for e in calendrier.walk("VEVENT")
               if e["DTSTART"].params.get("VALUE") == "DATE"
               and "aspirateur" in str(e["SUMMARY"]).lower()]
    assert rappels
    assert (rappels[0]["DTEND"].dt - rappels[0]["DTSTART"].dt).days == 1


def test_une_proposition_declinee_quitte_le_calendrier(client, thomas):
    _occuper(client, thomas, {12, 13})
    propositions.reperer(1)
    propositions.ecarter(propositions.en_attente(1)[0]["id_proposition"])

    flux = client.get("/planning.ics", params={"cle": JETON_THOMAS})
    calendrier = Calendar.from_ical(flux.content)
    assert not [e for e in calendrier.walk("VEVENT")
                if "Week-end libre" in str(e["SUMMARY"])]


# ---------------------------------------------------------------------------
# Par l'API et par le bot
# ---------------------------------------------------------------------------

def test_le_parcours_par_l_api(client, thomas):
    _occuper(client, thomas, {12, 13})

    assert client.post("/trajets/propositions/tour",
                       headers=thomas).json()["proposees"] == 1

    liste = client.get("/trajets/propositions", headers=thomas).json()
    assert len(liste) == 1

    client.delete(f"/trajets/propositions/{liste[0]['id_proposition']}", headers=thomas)
    assert client.get("/trajets/propositions", headers=thomas).json() == []


def test_decliner_une_proposition_inconnue_est_un_404(client, thomas):
    assert client.delete("/trajets/propositions/999999",
                         headers=thomas).status_code == 404


def test_seul_l_administrateur_declenche_la_ronde(client, lorette):
    assert client.post("/trajets/propositions/tour",
                       headers=lorette).status_code == 403


def test_le_bouton_voir_les_trains_retrouve_la_fenetre(client, thomas):
    from api import trajets

    _occuper(client, thomas, {12, 13})
    propositions.reperer(1)
    proposee = propositions.en_attente(1)[0]

    # C'est ce qui relie une proposition annoncée il y a quinze jours à la
    # fenêtre d'aujourd'hui, sans stocker de rang qui aurait vieilli.
    assert trajets.rang_contenant(1, proposee["debut"]) == 1


def test_si_le_creux_a_disparu_on_ne_propose_pas_de_train(client, thomas):
    from api import trajets

    _occuper(client, thomas, {12, 13})
    propositions.reperer(1)
    proposee = propositions.en_attente(1)[0]

    # Un cours tombe au milieu du week-end : la fenêtre n'existe plus.
    client.post("/occupations", headers=thomas, json={
        "type": "cours", "libelle": "Rattrapage",
        "debut": _minuit(12).replace(hour=10).isoformat(),
        "fin": _minuit(12).replace(hour=12).isoformat(),
    })

    assert trajets.rang_contenant(1, proposee["debut"]) is None
