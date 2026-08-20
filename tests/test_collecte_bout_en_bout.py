"""Collecte complète : du flux ADE jusqu'au calendrier du téléphone."""

from pathlib import Path

from icalendar import Calendar

EXEMPLE = (Path(__file__).parent / "exemple_ade.ics").read_text(encoding="utf-8")


def collecter(client, thomas, texte: str = EXEMPLE) -> dict:
    reponse = client.post("/sources/IDMC_ICS/collecter", headers=thomas,
                          params={"texte_ics": texte})
    assert reponse.status_code == 200, reponse.text
    bilan = reponse.json()

    # Invariant : chaque séance lue est comptée quelque part. C'est ce contrôle
    # qui a révélé que six chevauchements disparaissaient en silence.
    assert "non_comptabilisees" not in bilan, bilan
    return bilan


def test_chaque_seance_lue_est_comptabilisee(client, thomas):
    bilan = collecter(client, thomas)

    total = (bilan["crees"] + bilan["mis_a_jour"] + len(bilan["conflits"])
             + bilan["conflits_lointains"] + bilan["conflits_deja_signales"]
             + bilan["ecartees_par_arbitrage"] + sum(bilan["rejets"].values()))
    assert total == bilan["lues"]


def test_la_collecte_cree_les_occupations_filtrees(client, thomas):
    bilan = collecter(client, thomas)

    assert bilan["lues"] == 10
    assert bilan["crees"] == 6      # 10 séances moins 4 rejetées
    assert bilan["mis_a_jour"] == 0

    libelles = [o["libelle"] for o in client.get("/occupations", headers=thomas,
                                                 params={"debut": "2026-09-01T00:00:00Z",
                                                         "fin": "2026-09-30T00:00:00Z"}).json()]
    assert "TD CSI : Méthodes" in libelles
    assert "TPL Espagnol" in libelles
    assert not any("Chinois" in libelle for libelle in libelles)
    assert not any("Allemand" in libelle for libelle in libelles)


def test_une_seconde_collecte_met_a_jour_au_lieu_de_dupliquer(client, thomas):
    collecter(client, thomas)
    bilan = collecter(client, thomas)

    # R5 : la clé externe permet de retrouver l'occupation et de la corriger.
    assert bilan["crees"] == 0
    assert bilan["mis_a_jour"] == 6


def test_la_salle_et_l_enseignant_arrivent_dans_le_calendrier(client, thomas):
    collecter(client, thomas)

    occupations = client.get("/occupations", headers=thomas,
                             params={"debut": "2026-09-01T00:00:00Z",
                                     "fin": "2026-09-30T00:00:00Z"}).json()
    algo = next(o for o in occupations if "Algo IA" in o["libelle"])
    assert algo["lieu"] == "Amphi 201"

    flux = client.get("/planning.ics", params={"cle": "T" * 48, "jours": 400})
    calendrier = Calendar.from_ical(flux.content)

    evenements = {str(e["SUMMARY"]): e for e in calendrier.walk("VEVENT")}
    cours = next(e for nom, e in evenements.items() if "Algo IA" in nom)

    assert str(cours["LOCATION"]) == "Amphi 201"
    assert "BONNIN Geoffray" in str(cours["DESCRIPTION"])
    assert "Amphi 201" in str(cours["DESCRIPTION"])


def test_un_cours_disparu_du_flux_est_retire(client, thomas):
    collecter(client, thomas)

    # On rejoue le flux privé de l'espagnol : le cours a été annulé.
    ampute = EXEMPLE.replace("UID:ADE-ESPAGNOL", "UID:ADE-ESPAGNOL-SUPPRIME")
    ampute = "\n".join(
        ligne for ligne in ampute.splitlines() if "Espagnol" not in ligne
    )
    bilan = collecter(client, thomas, ampute)

    # Le cours d'espagnol est dans le futur : il disparaît.
    assert bilan["annules"] >= 1
    libelles = [o["libelle"] for o in client.get("/occupations", headers=thomas,
                                                 params={"debut": "2026-09-01T00:00:00Z",
                                                         "fin": "2026-09-30T00:00:00Z"}).json()]
    assert not any("Espagnol" in libelle for libelle in libelles)


def test_deux_cours_simultanes_ne_font_pas_echouer_la_collecte(client, thomas):
    # Le flux réel publie parfois deux CM à la même heure. La contrainte
    # d'exclusion en refuse un ; le reste doit être importé quand même.
    #
    # Ce conflit-ci est à plus de deux semaines : il n'est pas soumis à
    # arbitrage (R46). Le cas proche est couvert dans test_conflits.py.
    doublon = EXEMPLE.replace(
        "UID:ADE-SYSTEME",
        "UID:ADE-SYSTEME-BIS",
    ).replace("CM EC Système", "CM EC Réseaux")

    fusionne = EXEMPLE.replace("END:VCALENDAR", "")
    fusionne += "\n".join(doublon.splitlines()[5:])

    bilan = collecter(client, thomas, fusionne)

    assert bilan["crees"] == 6
    assert bilan["conflits"] == []


def test_la_source_passe_en_bonne_sante_apres_collecte(client, thomas):
    avant = next(s for s in client.get("/sources", headers=thomas).json()
                 if s["code"] == "IDMC_ICS")
    assert avant["derniere_collecte"] is None
    assert avant["etat_calcule"] == "en_panne"   # jamais collectée

    collecter(client, thomas)

    apres = next(s for s in client.get("/sources", headers=thomas).json()
                 if s["code"] == "IDMC_ICS")
    assert apres["derniere_collecte"] is not None
    assert apres["etat_calcule"] == "ok"


def test_la_collecte_refuse_une_source_qui_n_est_pas_un_flux(client, thomas):
    reponse = client.post("/sources/MANUELLE/collecter", headers=thomas,
                          params={"texte_ics": EXEMPLE})
    assert reponse.status_code == 400
    assert reponse.json()["code"] == "collecte_impossible"
