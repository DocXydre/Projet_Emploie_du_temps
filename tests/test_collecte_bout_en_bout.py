"""Collecte complète : du flux ADE jusqu'au calendrier du téléphone."""

import re
from datetime import UTC, date, datetime, timedelta
from pathlib import Path

import pytest
from icalendar import Calendar

from tests.conftest import JETON_THOMAS

# Le fichier d'exemple porte les dates réelles d'une semaine de septembre 2026.
# Les laisser telles quelles rendait la suite dépendante du jour où on la lance :
# cette semaine-là passée, les séances tombaient hors horizon et des tests
# échouaient sans que le code ait bougé. On recale donc le flux sur une semaine
# à venir, par un nombre entier de semaines pour que chaque séance garde son
# jour et son heure.
LUNDI_DU_FICHIER = date(2026, 9, 14)


def _lundi_cible() -> date:
    """Un lundi à plus de deux semaines d'ici.

    Au-delà du délai d'arbitrage de COL-11 : les conflits du flux d'exemple
    doivent rester lointains, ce dont un test dépend explicitement. Le plus
    proche que ce calcul produise est à quinze jours.
    """
    aujourd_hui = date.today()
    return aujourd_hui - timedelta(days=aujourd_hui.weekday()) + timedelta(weeks=3)


DECALAGE = _lundi_cible() - LUNDI_DU_FICHIER


def _recaler(texte: str) -> str:
    def decaler(trouve: re.Match) -> str:
        instant = datetime.strptime(trouve.group(2), "%Y%m%dT%H%M%SZ")
        return trouve.group(1) + (instant + DECALAGE).strftime("%Y%m%dT%H%M%SZ")

    return re.sub(r"(DTSTART:|DTEND:)(\d{8}T\d{6}Z)", decaler, texte)


EXEMPLE = _recaler((Path(__file__).parent / "exemple_ade.ics").read_text(encoding="utf-8"))

# La fenêtre suit le flux : les bornes en dur dataient, elles aussi.
FENETRE = {"debut": (datetime.now(UTC) - timedelta(days=1)).isoformat(),
           "fin": (datetime.now(UTC) + timedelta(days=90)).isoformat()}


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
                                                 params=FENETRE).json()]
    assert "TD CSI : Méthodes" in libelles
    assert "TPL Espagnol" in libelles
    assert not any("Chinois" in libelle for libelle in libelles)
    assert not any("Allemand" in libelle for libelle in libelles)


def test_une_seconde_collecte_met_a_jour_au_lieu_de_dupliquer(client, thomas):
    collecter(client, thomas)
    bilan = collecter(client, thomas)

    # COL-4 : la clé externe permet de retrouver l'occupation et de la corriger.
    assert bilan["crees"] == 0
    assert bilan["mis_a_jour"] == 6


def test_la_salle_et_l_enseignant_arrivent_dans_le_calendrier(client, thomas):
    collecter(client, thomas)

    occupations = client.get("/occupations", headers=thomas,
                             params=FENETRE).json()
    algo = next(o for o in occupations if "Algo IA" in o["libelle"])
    assert algo["lieu"] == "Amphi 201"

    flux = client.get("/planning.ics", params={"cle": JETON_THOMAS, "jours": 400})
    calendrier = Calendar.from_ical(flux.content)

    evenements = {str(e["SUMMARY"]): e for e in calendrier.walk("VEVENT")}
    cours = next(e for nom, e in evenements.items() if "Algo IA" in nom)

    assert str(cours["LOCATION"]) == "Amphi 201"
    assert "LEROY Marc" in str(cours["DESCRIPTION"])
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
                                                 params=FENETRE).json()]
    assert not any("Espagnol" in libelle for libelle in libelles)


def test_deux_cours_simultanes_ne_font_pas_echouer_la_collecte(client, thomas):
    # Le flux réel publie parfois deux CM à la même heure. La contrainte
    # d'exclusion en refuse un ; le reste doit être importé quand même.
    #
    # Ce conflit-ci est à plus de deux semaines : il n'est pas soumis à
    # arbitrage (COL-11). Le cas proche est couvert dans test_conflits.py.
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


# ---------------------------------------------------------------------------
# Relevé vide
#
# Leçon d'un incident réel : une collecte muette avait effacé deux semaines de
# shifts. Une page injoignable, un site refondu et une session expirée rendent
# tous zéro événement derrière un code 200.
# ---------------------------------------------------------------------------

VIDE = "\r\n".join([
    "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//exemple//FR", "END:VCALENDAR",
])


def test_un_releve_vide_n_efface_rien(client, thomas):
    from api.collecteurs.service import CollecteImpossible, collecter_source

    collecter(client, thomas, EXEMPLE)
    avant = client.get("/occupations", headers=thomas).json()
    assert avant, "il faut quelque chose à perdre pour que le test ait un sens"

    with pytest.raises(CollecteImpossible) as echec:
        collecter_source("IDMC_ICS", texte_ics=VIDE)
    assert echec.value.code == "releve_vide"

    apres = client.get("/occupations", headers=thomas).json()
    assert len(apres) == len(avant)


def test_une_source_neuve_accepte_un_flux_vide(client, thomas):
    # Rien à perdre : un calendrier qu'on vient de brancher et qui ne contient
    # encore rien n'est pas une panne.
    from api.collecteurs.service import collecter_source

    bilan = collecter_source("PERSO_THOMAS", texte_ics=VIDE)
    assert bilan["lues"] == 0
    assert bilan["annules"] == 0


def test_un_agenda_qui_se_vide_pour_de_bon_se_declare(client, thomas):
    # Fin de semestre : le flux ne publie plus rien, et c'est normal. La source
    # le dit dans sa configuration plutôt que de rester en panne pour toujours.
    from api.collecteurs.service import collecter_source

    collecter(client, thomas, EXEMPLE)
    client.patch("/sources/IDMC_ICS", headers=thomas,
                 json={"configuration": {"releve_vide_autorise": True}})

    bilan = collecter_source("IDMC_ICS", texte_ics=VIDE)
    assert bilan["annules"] >= 1
