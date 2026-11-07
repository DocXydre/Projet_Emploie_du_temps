"""Arbitrage des conflits horaires.

Une source publie parfois deux occupations au même moment. La contrainte
d'exclusion en refuse une ; la question est de savoir quoi faire de celle-là.
"""

from datetime import UTC, datetime, timedelta

import psycopg
import pytest

from tests.conftest import _url


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


def _sql(requete: str, *parametres):
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row, autocommit=True) as conn:
        curseur = conn.execute(requete, parametres or None)
        return curseur.fetchall() if curseur.description else []


def _conflit_dans(client, thomas, jours: int) -> int:
    """Un conflit horaire qui commence dans `jours` jours ; rend son numéro."""
    debut, fin = dans(jours, 10), dans(jours, 12)
    poser_occupation(client, thomas, debut, fin, "Cours déjà prévu")
    collecter(client, thomas, flux(f"VPT{jours}", debut, fin, "CM EC Autre chose"))
    return _sql("SELECT id_conflit FROM conflit ORDER BY id_conflit DESC LIMIT 1")[0]["id_conflit"]


# ---------------------------------------------------------------------------

def test_un_conflit_lointain_ne_derange_personne(client, thomas):
    # COL-11 : au-delà de deux semaines, l'emploi du temps a toutes les chances
    # d'être corrigé avant que ça compte.
    debut, fin = dans(25, 10), dans(25, 12)
    poser_occupation(client, thomas, debut, fin, "Cours déjà prévu")

    bilan = collecter(client, thomas, flux("LOINTAIN", debut, fin, "CM EC Autre chose"))

    assert bilan["conflits"] == []
    assert client.get("/conflits", headers=thomas).json() == []

    # Ne pas déranger n'est pas la même chose que perdre : la séance écartée
    # reste comptée, sinon des cours disparaîtraient sans laisser de trace.
    assert bilan["conflits_lointains"] == 1
    assert "non_comptabilisees" not in bilan


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


# ---------------------------------------------------------------------------
# Conflits caducs                                                  (COL-19, COL-20)
#
# Un conflit constaté un jour ne l'est pas pour toujours : la date passe, ou
# bien on choisit un groupe de TD et la séance rejetée disparaît du flux.
# ---------------------------------------------------------------------------

FLUX_VIDE = "BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:-//Test//FR\nEND:VCALENDAR\n"


def regler(client, thomas, **reglages) -> None:
    reponse = client.patch("/sources/IDMC_ICS", headers=thomas,
                           json={"configuration": reglages})
    assert reponse.status_code == 200, reponse.text


def test_un_conflit_passe_ne_se_propose_plus(client, thomas):
    # COL-19 : arbitrer un cours d'avant-hier ne change plus rien.
    debut, fin = dans(-3, 10), dans(-3, 12)
    poser_occupation(client, thomas, debut, fin, "Cours déjà prévu")

    collecter(client, thomas, flux("PASSE", debut, fin, "CM EC Autre chose"))

    assert client.get("/conflits", headers=thomas).json() == []
    # Il n'est pas perdu pour autant : l'historique des collectes reste lisible.
    tous = client.get("/conflits", headers=thomas, params={"tous": True}).json()
    assert [c["libelle_nouvelle"] for c in tous] == ["CM Autre chose"]


def test_ecarter_une_ue_ferme_le_conflit_qu_elle_causait(client, thomas):
    # COL-20 : deux options au même créneau. Dire laquelle on suit répond à la
    # question aussi sûrement qu'un arbitrage.
    debut, fin = dans(3, 10), dans(3, 12)
    poser_occupation(client, thomas, debut, fin, "Recherche opérationnelle")
    texte = flux("OPTION", debut, fin, "CM EC Traitement automatique des images")
    collecter(client, thomas, texte)
    assert len(client.get("/conflits", headers=thomas).json()) == 1

    regler(client, thomas, cours_ecartes=["Traitement automatique des images"])
    bilan = collecter(client, thomas, texte)

    assert bilan["conflits_perimes"] == 1
    assert client.get("/conflits", headers=thomas).json() == []

    tous = client.get("/conflits", headers=thomas, params={"tous": True}).json()
    assert tous[0]["statut"] == "caduc"
    assert tous[0]["motif_caducite"] == "sans_objet"


def test_choisir_un_groupe_ferme_le_conflit_avec_l_autre(client, thomas):
    # Avant d'avoir choisi, les deux groupes de TD arrivent tous les deux.
    regler(client, thomas, groupe=None)

    debut, fin = dans(3, 10), dans(3, 12)
    poser_occupation(client, thomas, debut, fin, "TD Bases de données")
    texte = flux("TD2", debut, fin, "TD Bases de données Gpe 2")
    collecter(client, thomas, texte)
    assert len(client.get("/conflits", headers=thomas).json()) == 1

    regler(client, thomas, groupe=1)
    collecter(client, thomas, texte)

    assert client.get("/conflits", headers=thomas).json() == []


def test_un_cours_retire_du_flux_ferme_son_conflit(client, thomas):
    debut, fin = dans(3, 10), dans(3, 12)
    poser_occupation(client, thomas, debut, fin, "Cours déjà prévu")
    collecter(client, thomas, flux("PROCHE", debut, fin, "CM EC Autre chose"))
    assert len(client.get("/conflits", headers=thomas).json()) == 1

    # L'ADE a corrigé : la séance en double n'est plus publiée.
    collecter(client, thomas, FLUX_VIDE)

    assert client.get("/conflits", headers=thomas).json() == []


def test_un_conflit_toujours_publie_reste_a_arbitrer(client, thomas):
    # Le revers du test précédent : périmer ne doit pas fermer les vraies
    # questions à la collecte suivante.
    debut, fin = dans(3, 10), dans(3, 12)
    poser_occupation(client, thomas, debut, fin, "Cours déjà prévu")
    texte = flux("PROCHE", debut, fin, "CM EC Autre chose")
    collecter(client, thomas, texte)

    bilan = collecter(client, thomas, texte)

    assert bilan["conflits_perimes"] == 0
    assert len(client.get("/conflits", headers=thomas).json()) == 1


def test_le_bouton_d_un_conflit_caduc_ne_ment_pas(client, thomas):
    debut, fin = dans(3, 10), dans(3, 12)
    poser_occupation(client, thomas, debut, fin, "Cours déjà prévu")
    collecter(client, thomas, flux("PROCHE", debut, fin, "CM EC Autre chose"))
    id_conflit = client.get("/conflits", headers=thomas).json()[0]["id_conflit"]

    collecter(client, thomas, FLUX_VIDE)

    # L'écran de l'appli est plus ancien que la collecte : dire « déjà tranché »
    # laisserait croire à un choix qu'on n'a pas fait.
    reponse = client.post(f"/conflits/{id_conflit}/resoudre", headers=thomas,
                          json={"garder": "nouvelle"})
    assert reponse.status_code == 409 and reponse.json()["code"] == "conflit_caduc"
    assert "n'existe plus" in reponse.json()["message"]
    assert [o["libelle"] for o in client.get("/occupations", headers=thomas).json()] \
        == ["Cours déjà prévu"]


def test_le_report_de_minuit_perime_les_conflits_passes(client, thomas):
    from api.ordonnanceur import report_de_minuit

    debut, fin = dans(-2, 10), dans(-2, 12)
    poser_occupation(client, thomas, debut, fin, "Cours déjà prévu")
    collecter(client, thomas, flux("PASSE", debut, fin, "CM EC Autre chose"))

    bilan = report_de_minuit()

    assert bilan["conflits_perimes"] == 1
    tous = client.get("/conflits", headers=thomas, params={"tous": True}).json()
    assert tous[0]["motif_caducite"] == "passe"


# ---------------------------------------------------------------------------
# « Voir plus tard »                                                  (COL-23)
# ---------------------------------------------------------------------------


def test_un_conflit_ne_se_cache_pas_au_dela_de_sept_jours_avant_sa_date(client, thomas):
    numero = _conflit_dans(client, thomas, 10)
    assert (
        _sql("SELECT cache_jusqu_a FROM conflit WHERE id_conflit = %s", numero)[0]["cache_jusqu_a"]
        is None
    )

    # Sept jours avant sa date : permis.
    _sql(
        "UPDATE conflit SET cache_jusqu_a = lower(periode) - INTERVAL '7 days' "
        "WHERE id_conflit = %s",
        numero,
    )
    # Six jours avant : la base refuse.
    with pytest.raises(psycopg.errors.CheckViolation):
        _sql(
            "UPDATE conflit SET cache_jusqu_a = lower(periode) - INTERVAL '6 days' "
            "WHERE id_conflit = %s",
            numero,
        )


def test_voir_plus_tard_cache_le_conflit_jusqu_a_sept_jours_avant(client, thomas):
    numero = _conflit_dans(client, thomas, 10)

    reponse = client.post(f"/conflits/{numero}/plus-tard", headers=thomas)

    assert reponse.status_code == 200, reponse.text
    assert reponse.json()["id_conflit"] == numero
    ligne = _sql(
        "SELECT cache_jusqu_a = lower(periode) - INTERVAL '7 days' AS sept_jours "
        "FROM conflit WHERE id_conflit = %s",
        numero,
    )[0]
    assert ligne["sept_jours"] is True
    assert client.get("/conflits", headers=thomas).json() == []
    tous = client.get("/conflits", headers=thomas, params={"tous": True}).json()
    assert [c["id_conflit"] for c in tous] == [numero]
    assert tous[0]["a_arbitrer"] is False and tous[0]["cache_jusqu_a"] is not None
    # Caché, il ne se recache pas.
    assert client.post(f"/conflits/{numero}/plus-tard", headers=thomas).status_code == 409


def test_un_conflit_cache_revient_puis_ne_se_cache_plus(client, thomas):
    numero = _conflit_dans(client, thomas, 10)
    client.post(f"/conflits/{numero}/plus-tard", headers=thomas)

    # Le temps passe : la date de retour est derrière nous.
    _sql(
        "UPDATE conflit SET cache_jusqu_a = now() - INTERVAL '1 minute' WHERE id_conflit = %s",
        numero,
    )

    revenus = client.get("/conflits", headers=thomas).json()
    assert [c["id_conflit"] for c in revenus] == [numero]
    assert revenus[0]["a_arbitrer"] is True
    reponse = client.post(f"/conflits/{numero}/plus-tard", headers=thomas)
    assert reponse.status_code == 409
    assert reponse.json()["code"] == "regle_metier"
    assert "déjà" in reponse.json()["message"]


def test_un_conflit_a_moins_de_sept_jours_ne_se_cache_pas(client, thomas):
    numero = _conflit_dans(client, thomas, 3)

    reponse = client.post(f"/conflits/{numero}/plus-tard", headers=thomas)

    assert reponse.status_code == 409
    assert "moins de sept jours" in reponse.json()["message"]
    assert (
        _sql("SELECT cache_jusqu_a FROM conflit WHERE id_conflit = %s", numero)[0]["cache_jusqu_a"]
        is None
    )
    assert [c["id_conflit"] for c in client.get("/conflits", headers=thomas).json()] == [numero]


def test_voir_plus_tard_sur_un_conflit_inconnu(client, thomas):
    reponse = client.post("/conflits/999999/plus-tard", headers=thomas)

    assert reponse.status_code == 404
    assert reponse.json()["code"] == "introuvable"


def test_un_conflit_regle_ne_se_cache_pas(client, thomas):
    numero = _conflit_dans(client, thomas, 10)
    client.post(f"/conflits/{numero}/resoudre", headers=thomas, json={"garder": "existante"})

    reponse = client.post(f"/conflits/{numero}/plus-tard", headers=thomas)

    assert reponse.status_code == 409
    assert "réglé" in reponse.json()["message"]


def test_un_conflit_cache_quitte_aujourd_hui(client, thomas):
    """COL-23 : le bandeau d'Aujourd'hui, où est le bouton, ne montre plus le conflit caché."""
    numero = _conflit_dans(client, thomas, 10)
    avant = client.get("/appli/aujourdhui", headers=thomas).json()["conflit"]
    assert avant is not None and avant["id"] == numero

    assert client.post(f"/conflits/{numero}/plus-tard", headers=thomas).status_code == 200
    assert client.get("/appli/aujourdhui", headers=thomas).json()["conflit"] is None


def test_le_conflit_d_un_autre_ne_se_cache_ni_ne_se_tranche(client, thomas, lorette):
    numero = _conflit_dans(client, thomas, 10)

    cacher = client.post(f"/conflits/{numero}/plus-tard", headers=lorette)
    trancher = client.post(
        f"/conflits/{numero}/resoudre", headers=lorette, json={"garder": "existante"}
    )

    assert cacher.status_code == 404 and trancher.status_code == 404
    assert client.get("/conflits", headers=lorette, params={"tous": True}).json() == []
    ligne = _sql("SELECT statut, cache_jusqu_a FROM conflit WHERE id_conflit = %s", numero)[0]
    assert ligne == {"statut": "en_attente", "cache_jusqu_a": None}
