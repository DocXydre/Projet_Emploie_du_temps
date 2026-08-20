"""Arbitrage des conflits horaires.

Une source publie parfois deux occupations au même moment. La contrainte
d'exclusion en refuse une ; la question est de savoir quoi faire de celle-là.
"""

from datetime import UTC, datetime, timedelta


def dans(jours: int, heure: int) -> datetime:
    base = datetime.now(UTC) + timedelta(days=jours)
    return base.replace(hour=heure, minute=0, second=0, microsecond=0)


def flux(uid: str, debut: datetime, fin: datetime, titre: str) -> str:
    return f"""BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//FR
BEGIN:VEVENT
UID:{uid}
DTSTART:{debut.strftime('%Y%m%dT%H%M%SZ')}
DTEND:{fin.strftime('%Y%m%dT%H%M%SZ')}
SUMMARY:{titre}
LOCATION:Salle 104 (49 Places)
DESCRIPTION:\\n\\nBRUN Armelle\\n\\n(Modifié le:19/06/2026)
END:VEVENT
END:VCALENDAR
"""


def poser_occupation(client, thomas, debut: datetime, fin: datetime, libelle: str) -> None:
    reponse = client.post("/occupations", headers=thomas, json={
        "type": "cours", "libelle": libelle,
        "debut": debut.isoformat(), "fin": fin.isoformat(),
    })
    assert reponse.status_code == 201, reponse.text


def collecter(client, thomas, texte: str) -> dict:
    reponse = client.post("/sources/IDMC_ICS/collecter", headers=thomas,
                          params={"texte_ics": texte})
    assert reponse.status_code == 200, reponse.text
    return reponse.json()


# ---------------------------------------------------------------------------

def test_un_conflit_lointain_ne_derange_personne(client, thomas):
    # R46 : au-delà de deux semaines, l'emploi du temps a toutes les chances
    # d'être corrigé avant que ça compte.
    debut, fin = dans(25, 10), dans(25, 12)
    poser_occupation(client, thomas, debut, fin, "Cours déjà prévu")

    bilan = collecter(client, thomas, flux("LOINTAIN", debut, fin, "CM EC Autre chose"))

    assert bilan["conflits"] == []
    assert client.get("/conflits", headers=thomas).json() == []


def test_un_conflit_proche_demande_un_arbitrage(client, thomas):
    debut, fin = dans(3, 10), dans(3, 12)
    poser_occupation(client, thomas, debut, fin, "Cours déjà prévu")

    bilan = collecter(client, thomas, flux("PROCHE", debut, fin, "CM EC Autre chose"))

    assert bilan["conflits"], "un conflit à trois jours doit être signalé"

    conflits = client.get("/conflits", headers=thomas).json()
    assert len(conflits) == 1

    conflit = conflits[0]
    assert conflit["libelle_existante"] == "Cours déjà prévu"
    assert conflit["libelle_nouvelle"] == "CM Autre chose"
    assert conflit["a_arbitrer"] is True
    # Les deux versions sont côte à côte : le bot n'a rien à recalculer.
    assert conflit["lieu_nouvelle"] == "Salle 104"


def test_garder_l_existante_ecarte_durablement_la_nouvelle(client, thomas):
    debut, fin = dans(3, 10), dans(3, 12)
    poser_occupation(client, thomas, debut, fin, "Cours déjà prévu")
    texte = flux("PROCHE", debut, fin, "CM EC Autre chose")
    collecter(client, thomas, texte)

    conflit = client.get("/conflits", headers=thomas).json()[0]
    resolution = client.post(f"/conflits/{conflit['id_conflit']}/resoudre",
                             headers=thomas, json={"garder": "existante"})
    assert resolution.status_code == 200

    # Le planning n'a pas bougé.
    occupations = client.get("/occupations", headers=thomas).json()
    assert [o["libelle"] for o in occupations] == ["Cours déjà prévu"]

    # Et la question ne se repose pas à la collecte suivante.
    bilan = collecter(client, thomas, texte)
    assert bilan["conflits"] == []
    assert client.get("/conflits", headers=thomas).json() == []


def test_garder_la_nouvelle_remplace_l_existante(client, thomas):
    debut, fin = dans(3, 10), dans(3, 12)
    poser_occupation(client, thomas, debut, fin, "Cours déjà prévu")
    collecter(client, thomas, flux("PROCHE", debut, fin, "CM EC Autre chose"))

    conflit = client.get("/conflits", headers=thomas).json()[0]
    resolution = client.post(f"/conflits/{conflit['id_conflit']}/resoudre",
                             headers=thomas, json={"garder": "nouvelle"})
    assert resolution.status_code == 200

    occupations = client.get("/occupations", headers=thomas).json()
    libelles = [o["libelle"] for o in occupations]
    assert libelles == ["CM Autre chose"]
    assert occupations[0]["lieu"] == "Salle 104"


def test_un_conflit_deja_tranche_ne_se_rejoue_pas(client, thomas):
    debut, fin = dans(3, 10), dans(3, 12)
    poser_occupation(client, thomas, debut, fin, "Cours déjà prévu")
    texte = flux("PROCHE", debut, fin, "CM EC Autre chose")
    collecter(client, thomas, texte)

    conflit = client.get("/conflits", headers=thomas).json()[0]
    client.post(f"/conflits/{conflit['id_conflit']}/resoudre",
                headers=thomas, json={"garder": "existante"})

    reponse = client.post(f"/conflits/{conflit['id_conflit']}/resoudre",
                          headers=thomas, json={"garder": "nouvelle"})
    assert reponse.status_code == 404


def test_un_conflit_proche_cree_une_notification(client, thomas, base):
    import psycopg

    from tests.conftest import _url

    debut, fin = dans(3, 10), dans(3, 12)
    poser_occupation(client, thomas, debut, fin, "Cours déjà prévu")
    collecter(client, thomas, flux("PROCHE", debut, fin, "CM EC Autre chose"))

    with psycopg.connect(_url()) as conn:
        alertes = conn.execute(
            "SELECT contenu FROM notification WHERE type = 'alerte'"
        ).fetchall()

    assert alertes
    assert "conflit" in alertes[0][0]


# ---------------------------------------------------------------------------
# Configuration des sources depuis le bot
# ---------------------------------------------------------------------------

def test_on_peut_donner_l_url_depuis_le_bot(client, thomas):
    reponse = client.patch("/sources/MCDO", headers=thomas,
                           json={"url": "https://exemple.fr/calendar?api_token=secret"})
    assert reponse.status_code == 200

    # L'URL n'est jamais renvoyée : elle contient un jeton d'accès.
    corps = reponse.json()
    assert "url" not in corps
    assert corps["url_renseignee"] is True


def test_collecter_sans_url_le_dit_clairement(client, thomas):
    reponse = client.post("/sources/MCDO/collecter", headers=thomas)
    assert reponse.status_code == 409
    assert reponse.json()["code"] == "url_absente"


def test_changer_de_groupe_est_un_reglage(client, thomas):
    reponse = client.patch("/sources/IDMC_ICS", headers=thomas, json={
        "configuration": {"profil": "ade", "groupe": 2,
                          "langues_suivies": ["anglais"],
                          "langues_possibles": ["anglais", "espagnol"]},
    })
    assert reponse.status_code == 200
    assert reponse.json()["configuration"]["groupe"] == 2
