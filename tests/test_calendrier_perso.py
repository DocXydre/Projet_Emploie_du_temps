"""Calendriers personnels : chacun tient le sien dans son application.

L'université publie, McDonald's publie, on collecte. Lorette n'a rien de tel,
et Thomas a des choses qui ne figurent dans aucun de ces deux flux. La solution
qui demande le moins : tenir son calendrier là où on le tient déjà, le publier,
et donner le lien.

Le collecteur ne change pas — seul le profil de lecture diffère. Il n'y a rien
à nettoyer dans ce qu'une personne a écrit elle-même : corriger serait présumer.
"""

from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import psycopg

from api import conversation as conv
from api.collecteurs import ics
from tests.conftest import CLE_LORETTE, CLE_THOMAS, _url

PARIS = ZoneInfo("Europe/Paris")


def _calendrier(*evenements) -> str:
    """Un flux tel qu'Apple Calendrier en publie un."""
    lignes = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Apple Inc.//iOS 18//FR"]
    for uid, resume, debut, fin, lieu in evenements:
        lignes += [
            "BEGIN:VEVENT",
            f"UID:{uid}",
            f"SUMMARY:{resume}",
            f"DTSTART;TZID=Europe/Paris:{debut:%Y%m%dT%H%M%S}",
            f"DTEND;TZID=Europe/Paris:{fin:%Y%m%dT%H%M%S}",
        ]
        if lieu:
            lignes.append(f"LOCATION:{lieu}")
        lignes.append("END:VEVENT")
    lignes.append("END:VCALENDAR")
    return "\r\n".join(lignes)


def _demain(heure: int) -> datetime:
    return (datetime.now(PARIS) + timedelta(days=1)).replace(
        hour=heure, minute=0, second=0, microsecond=0)


def identifiant(client, cle: str) -> int:
    return client.get("/moi", headers={"X-Cle-Api": cle}).json()["id_utilisateur"]


# ---------------------------------------------------------------------------
# Lien d'abonnement
# ---------------------------------------------------------------------------

def test_un_lien_webcal_devient_une_adresse_https(base):
    # Apple, Google et Outlook proposent tous « webcal:// ». Ce n'est pas un
    # protocole : c'est du HTTPS avec un préfixe pour l'application Calendrier.
    assert conv.url_collectable("webcal://p12.icloud.com/x/abcd.ics") \
        == "https://p12.icloud.com/x/abcd.ics"
    assert conv.url_collectable("WEBCAL://exemple.fr/a.ics") \
        == "https://exemple.fr/a.ics"


def test_une_adresse_https_n_est_pas_touchee(base):
    assert conv.url_collectable(" https://exemple.fr/a.ics ") == "https://exemple.fr/a.ics"


def test_donner_l_url_convertit_et_active(client, thomas):
    avant = [s for s in client.get("/sources", headers=thomas).json()
             if s["code"] == "PERSO_LORETTE"][0]
    assert avant["active"] is False

    reponse = client.patch("/sources/PERSO_LORETTE", headers=thomas,
                           json={"url": "webcal://p12.icloud.com/x/lorette.ics"})

    # Donner l'URL vaut demande de collecte : une source renseignée mais
    # laissée éteinte n'a pas de raison d'être.
    assert reponse.json()["active"] is True
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row) as conn:
        stockee = conn.execute(
            "SELECT url FROM source WHERE code = 'PERSO_LORETTE'").fetchone()["url"]
    assert stockee.startswith("https://")


def test_desactiver_explicitement_reste_possible(client, thomas):
    client.patch("/sources/PERSO_THOMAS", headers=thomas,
                 json={"url": "https://exemple.fr/a.ics"})
    reponse = client.patch("/sources/PERSO_THOMAS", headers=thomas,
                           json={"active": False})
    assert reponse.json()["active"] is False


# ---------------------------------------------------------------------------
# Rattachement
# ---------------------------------------------------------------------------

def test_chaque_calendrier_va_a_son_proprietaire(client, thomas, lorette):
    sources = {s["code"]: s for s in client.get("/sources", headers=thomas).json()}

    # R85 : sans ce rattachement nommé, `appliquer_assignations` donnerait à
    # l'administrateur toute source encore orpheline — dont celle de Lorette.
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row) as conn:
        proprietaires = {
            ligne["code"]: ligne["pseudo"]
            for ligne in conn.execute(
                "SELECT s.code, u.pseudo FROM source s "
                "  JOIN utilisateur u ON u.id_utilisateur = s.id_utilisateur "
                " WHERE s.code LIKE 'PERSO_%'").fetchall()
        }

    assert proprietaires["PERSO_THOMAS"] == "thomas"
    assert proprietaires["PERSO_LORETTE"] == "lorette"
    assert sources["PERSO_LORETTE"]["mode_collecte"] == "ics"


# ---------------------------------------------------------------------------
# Lecture du calendrier
# ---------------------------------------------------------------------------

def test_un_evenement_saisi_a_la_main_n_est_pas_retouche(base):
    debut, fin = _demain(14), _demain(16)
    lues = ics.analyser(_calendrier(
        ("evt-1@icloud", "Rendez-vous médecin", debut, fin, "Cabinet, rue Stanislas"),
    ), profil="perso")

    assert len(lues) == 1
    # Les profils ADE et Easy at Work nettoient parce qu'ils lisent des flux
    # engendrés par des machines. Ici, corriger serait présumer.
    assert lues[0].libelle == "Rendez-vous médecin"
    assert lues[0].lieu == "Cabinet, rue Stanislas"


def test_un_evenement_sans_lieu_reste_sans_lieu(base):
    lues = ics.analyser(_calendrier(
        ("evt-2@icloud", "Cours de danse", _demain(18), _demain(20), None),
    ), profil="perso")
    assert lues[0].lieu is None


def test_aucun_filtre_de_groupe_ni_de_langue_ne_s_applique(base):
    # Ces filtres sont ceux de l'emploi du temps universitaire. Appliqués à un
    # calendrier personnel, ils supprimeraient un cours d'espagnol du soir.
    seances = ics.analyser(_calendrier(
        ("evt-3@icloud", "Cours d'espagnol gpe 2", _demain(19), _demain(21), None),
    ), profil="perso")

    garder, motif = ics.a_garder(seances[0], {"profil": "perso",
                                              "type_occupation": "autre"})
    assert garder is True, motif


def test_la_collecte_ecrit_les_occupations_de_lorette(client, lorette, thomas):
    debut, fin = _demain(14), _demain(16)
    flux = _calendrier(("evt-4@icloud", "Travail", debut, fin, "Bureau"))

    bilan = client.post("/sources/PERSO_LORETTE/collecter", headers=thomas,
                        params={"texte_ics": flux}).json()
    assert bilan["crees"] == 1

    planning = client.get("/planning", headers=lorette).json()
    sien = [ligne for ligne in planning if ligne["libelle"] == "Travail"]
    assert sien and sien[0]["id_utilisateur"] == identifiant(client, CLE_LORETTE)


def test_deux_evenements_qui_se_chevauchent_passent(client, thomas):
    # R84 : un calendrier personnel contient souvent un rendez-vous posé sur
    # une plage plus large. Refuser la collecte pour ça serait absurde.
    flux = _calendrier(
        ("evt-5@icloud", "Journée famille", _demain(9), _demain(20), None),
        ("evt-6@icloud", "Déjeuner", _demain(12), _demain(13), None),
    )

    bilan = client.post("/sources/PERSO_THOMAS/collecter", headers=thomas,
                        params={"texte_ics": flux}).json()
    assert bilan["crees"] == 2
    assert bilan.get("conflits_arbitrables", 0) == 0


def test_une_occupation_perso_bloque_le_menage(client, thomas):
    # Elle n'est pas de type « cours », mais elle occupe : le placement doit
    # en tenir compte comme de n'importe quelle autre occupation.
    debut = (datetime.now(PARIS) + timedelta(days=1)).replace(
        hour=0, minute=0, second=0, microsecond=0)
    flux = _calendrier(
        ("evt-7@icloud", "Journée pleine", debut + timedelta(minutes=1),
         debut + timedelta(days=1) - timedelta(minutes=1), None),
    )
    client.post("/sources/PERSO_THOMAS/collecter", headers=thomas,
                params={"texte_ics": flux})

    moi = identifiant(client, CLE_THOMAS)
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row) as conn:
        libre = conn.execute(
            "SELECT temps_libre_jour(%s, %s::DATE) AS libre",
            (moi, debut.date()),
        ).fetchone()["libre"]

    assert libre < timedelta(minutes=5)
