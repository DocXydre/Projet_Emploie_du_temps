"""Collecteur ADE, sur un extrait réel du flux de l'Université de Lorraine.

L'extrait reproduit fidèlement les pièges du vrai flux : doublons d'UID entre
une version vide et une version enrichie, « SALLE A DEFINIR », capacités entre
parenthèses, code de bâtiment collé à la salle, orthographe variable du groupe.
"""

from datetime import date
from pathlib import Path

from api.collecteurs.ics import (
    a_garder,
    analyser,
    collecter,
    extraire_enseignant,
    groupe_de,
    nettoyer_libelle,
    nettoyer_salle,
    url_fenetre_glissante,
)

EXEMPLE = (Path(__file__).parent / "exemple_ade.ics").read_text(encoding="utf-8")

CONFIGURATION = {
    "groupe": 1,
    "langues_suivies": ["anglais", "espagnol"],
    "langues_possibles": ["anglais", "espagnol", "chinois", "allemand"],
    "horizon_jours": 60,
}


# ---------------------------------------------------------------------------
# Extraction champ par champ
# ---------------------------------------------------------------------------

def test_la_salle_a_definir_n_est_pas_une_salle():
    assert nettoyer_salle("SALLE A DEFINIR") is None
    assert nettoyer_salle("") is None
    assert nettoyer_salle(None) is None


def test_la_capacite_et_le_batiment_sont_retires():
    assert nettoyer_salle("Salle 104 (49 Places)") == "Salle 104"
    assert nettoyer_salle("Salle 004 ( 49 Places)") == "Salle 004"
    assert nettoyer_salle("Amphi 201 (115 places)") == "Amphi 201"
    # Le « 105 » est un code de bâtiment, pas une salle.
    assert nettoyer_salle("105\\,Salle 104 (49 Places)") == "Salle 104"
    assert nettoyer_salle("Salle 206/207 (60 Places)") == "Salle 206/207"


def test_plusieurs_salles_sont_conservees():
    assert nettoyer_salle("Salle 003 (24 Places)\\,Salle 004") == "Salle 003 / Salle 004"


def test_l_enseignant_est_extrait_de_la_description():
    assert extraire_enseignant("\\n\\nVIGNERON Laurent\\nCSI\\n\\n(Modifié le:03/07)") \
        == "VIGNERON Laurent"
    # Le nom n'est pas toujours en tête de description.
    assert extraire_enseignant("\\n\\nCSI : Optimisation\\nBRUN Armelle\\n\\n(Modifié le:19/06)") \
        == "BRUN Armelle"


def test_l_anonymisation_du_flux_public_n_est_pas_un_nom():
    # « Enseignant 1 » est ce que publie l'ADE quand le nom n'est pas diffusé.
    # L'afficher serait pire que ne rien afficher.
    assert extraire_enseignant("\\n\\nEnseignant 1\\n7JEMEN11PO|7JMEN1101\\n\\n(Modifié)") is None


def test_les_codes_de_maquette_ne_sont_pas_des_noms():
    assert extraire_enseignant("\\n\\n7JEMEN11PO|7JMEN1102\\n\\n(Modifié le:19/06)") is None


def test_le_groupe_se_lit_dans_les_deux_orthographes():
    assert groupe_de("TP Tech de comm gpe1") == 1
    assert groupe_de("TD Algo IA gpe 2") == 2
    assert groupe_de("Anglais gpe 1") == 1
    assert groupe_de("CM EC Système") is None


def test_le_libelle_est_nettoye():
    assert nettoyer_libelle("CM EC Recherche Opérationnelle") == "CM Recherche Opérationnelle"
    assert nettoyer_libelle("TD Algo IA gpe 2") == "TD Algo IA"
    assert nettoyer_libelle("TP Tech de comm gpe1") == "TP Tech de comm"


# ---------------------------------------------------------------------------
# Fusion des doublons
# ---------------------------------------------------------------------------

def test_les_doublons_d_uid_sont_fusionnes_en_gardant_le_plus_riche():
    seances = analyser(EXEMPLE)
    methodes = [s for s in seances if s.cle_externe == "ADE-CSI-METHODES-GPE1"]

    # Deux VEVENT dans le flux, une seule séance en sortie.
    assert len(methodes) == 1

    # C'est la version enrichie qui gagne : sans cela, l'enseignant serait perdu.
    assert methodes[0].details == "Enseignant : VIGNERON Laurent"
    # La salle reste vide, elle n'est pas encore attribuée.
    assert methodes[0].lieu is None


def test_toutes_les_seances_distinctes_sont_lues():
    seances = analyser(EXEMPLE)
    # 11 VEVENT dont 2 partagent un UID : 10 séances distinctes.
    assert len(seances) == 10
    assert len({s.cle_externe for s in seances}) == 10


def test_les_seances_sont_triees_chronologiquement():
    seances = analyser(EXEMPLE)
    assert seances == sorted(seances, key=lambda s: s.debut)


# ---------------------------------------------------------------------------
# Filtres
# ---------------------------------------------------------------------------

def test_les_langues_non_suivies_sont_ecartees():
    seances = {s.cle_externe: s for s in analyser(EXEMPLE)}

    garde, motif = a_garder(seances["ADE-CHINOIS"], CONFIGURATION)
    assert not garde and "chinois" in motif

    garde, motif = a_garder(seances["ADE-ALLEMAND"], CONFIGURATION)
    assert not garde and "allemand" in motif

    assert a_garder(seances["ADE-ESPAGNOL"], CONFIGURATION)[0]


def test_le_groupe_2_est_ecarte():
    seances = {s.cle_externe: s for s in analyser(EXEMPLE)}

    assert not a_garder(seances["ADE-CSI-METHODES-GPE2"], CONFIGURATION)[0]
    assert not a_garder(seances["ADE-ANGLAIS-GPE2"], CONFIGURATION)[0]
    assert a_garder(seances["ADE-CSI-METHODES-GPE1"], CONFIGURATION)[0]
    assert a_garder(seances["ADE-ANGLAIS-GPE1"], CONFIGURATION)[0]


def test_un_cours_sans_groupe_est_garde():
    seances = {s.cle_externe: s for s in analyser(EXEMPLE)}
    assert a_garder(seances["ADE-SYSTEME"], CONFIGURATION)[0]


def test_changer_de_groupe_ne_demande_qu_un_reglage():
    seances = {s.cle_externe: s for s in analyser(EXEMPLE)}
    groupe2 = {**CONFIGURATION, "groupe": 2}

    assert a_garder(seances["ADE-CSI-METHODES-GPE2"], groupe2)[0]
    assert not a_garder(seances["ADE-CSI-METHODES-GPE1"], groupe2)[0]


def test_collecte_complete_avec_bilan_des_rejets():
    resultat = collecter("http://exemple", CONFIGURATION, texte_ics=EXEMPLE)

    assert resultat["lues"] == 10
    codes = {s.cle_externe for s in resultat["seances"]}

    assert "ADE-CHINOIS" not in codes
    assert "ADE-ALLEMAND" not in codes
    assert "ADE-CSI-METHODES-GPE2" not in codes
    assert "ADE-ANGLAIS-GPE2" not in codes

    assert "ADE-ESPAGNOL" in codes
    assert "ADE-ANGLAIS-GPE1" in codes
    assert "ADE-SYSTEME" in codes

    # Le bilan explique ce qui a été jeté : une collecte muette est indébogable.
    assert sum(resultat["rejets"].values()) == 4


# ---------------------------------------------------------------------------
# Détails exportés dans le calendrier
# ---------------------------------------------------------------------------

def test_les_details_portent_la_salle_et_l_enseignant():
    seances = {s.cle_externe: s for s in analyser(EXEMPLE)}

    algo = seances["ADE-ALGO-IA-GPE1"]
    assert algo.details == "Salle : Amphi 201\nEnseignant : BONNIN Geoffray"

    # Salle connue, enseignant anonymisé.
    tech = seances["ADE-TECH-COMM-GPE1"]
    assert tech.details == "Salle : Salle 104"

    # Ni l'un ni l'autre : pas de description vide dans le calendrier.
    assert seances["ADE-SYSTEME"].details is None


# ---------------------------------------------------------------------------
# Fenêtre glissante
# ---------------------------------------------------------------------------

def test_les_dates_du_flux_suivent_le_temps():
    url = ("https://planning.univ-lorraine.fr/jsp/custom/modules/plannings/"
           "anonymous_cal.jsp?resources=25661&projectId=14&calType=ical"
           "&firstDate=2026-09-03&lastDate=2026-12-30")

    recalee = url_fenetre_glissante(url, 30, aujourd_hui=date(2026, 11, 1))

    assert "firstDate=2026-11-01" in recalee
    assert "lastDate=2026-12-01" in recalee
    # Les autres paramètres sont préservés.
    assert "resources=25661" in recalee
    assert "projectId=14" in recalee
