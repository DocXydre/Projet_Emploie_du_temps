"""Collecteur du planning McDonald's (Easy at Work).

Extrait réel du flux, anonymisé. Beaucoup plus simple que l'ADE : un UID stable
par shift, pas de doublon, un titre toujours identique. La seule subtilité est
que le flux traîne plusieurs mois de passé.
"""

from datetime import UTC, datetime, timedelta
from pathlib import Path

from api.collecteurs.ics import analyser, collecter

EXEMPLE = (Path(__file__).parent / "exemple_mcdo.ics").read_text(encoding="utf-8")

# Le flux d'exemple est daté : on se place au moment où il a été capturé.
CAPTURE = datetime(2026, 8, 19, 22, 32, tzinfo=UTC)

CONFIGURATION = {
    "profil": "easyatwork",
    "type_occupation": "travail",
    "horizon_jours": 30,
    "historique_jours": 7,
}


def test_le_titre_donne_le_libelle_et_le_lieu():
    seances = {s.cle_externe: s for s in analyser(EXEMPLE, "easyatwork")}
    shift = seances["shift-1@api.easyatwork.com"]

    assert shift.libelle == "Shift McDonald's"
    assert shift.lieu == "NANCY CENTRE"
    assert shift.details is None


def test_les_horaires_sont_lus_en_utc():
    seances = {s.cle_externe: s for s in analyser(EXEMPLE, "easyatwork")}
    shift = seances["shift-1@api.easyatwork.com"]

    assert shift.debut == datetime(2026, 8, 30, 16, 0, tzinfo=UTC)
    assert shift.fin == datetime(2026, 8, 30, 20, 0, tzinfo=UTC)


def test_le_passe_lointain_n_est_pas_recharge():
    # Le flux contient des shifts de juin : inutile de les réimporter chaque
    # jour, et surtout ils ne servent plus à rien.
    resultat = collecter("http://exemple", CONFIGURATION,
                         texte_ics=EXEMPLE, maintenant=CAPTURE)

    codes = {s.cle_externe for s in resultat["seances"]}
    assert "shift-ancien@api.easyatwork.com" not in codes
    assert resultat["rejets"]["hors horizon (passé)"] == 1


def test_l_horizon_borne_aussi_le_futur():
    resultat = collecter("http://exemple", CONFIGURATION,
                         texte_ics=EXEMPLE, maintenant=CAPTURE)

    codes = {s.cle_externe for s in resultat["seances"]}
    assert "shift-lointain@api.easyatwork.com" not in codes
    assert resultat["rejets"]["hors horizon (futur)"] == 1


def test_les_shifts_de_la_fenetre_sont_gardes():
    resultat = collecter("http://exemple", CONFIGURATION,
                         texte_ics=EXEMPLE, maintenant=CAPTURE)

    codes = {s.cle_externe for s in resultat["seances"]}
    assert codes == {
        "shift-1@api.easyatwork.com",
        "shift-2@api.easyatwork.com",
        "shift-3@api.easyatwork.com",
    }


def test_les_filtres_de_l_ade_ne_s_appliquent_pas():
    # Ni groupe, ni langue : un shift n'a rien à voir avec une maquette.
    resultat = collecter("http://exemple",
                         {**CONFIGURATION, "groupe": 1,
                          "langues_possibles": ["espagnol"], "langues_suivies": []},
                         texte_ics=EXEMPLE, maintenant=CAPTURE)
    assert len(resultat["seances"]) == 3


def test_une_url_sans_bornes_de_dates_n_est_pas_modifiee():
    from api.collecteurs.ics import url_fenetre_glissante

    url = "https://eu-west-3.api.easyatwork.com/calendar?api_token=xxx&customer_ids[]=1"
    assert url_fenetre_glissante(url, 30) == url


def test_l_alternance_retire_l_espagnol():
    from api.collecteurs.ics import Seance, a_garder

    espagnol = Seance(cle_externe="x", libelle="TPL Espagnol",
                      debut=CAPTURE, fin=CAPTURE + timedelta(hours=2))
    reglages = {
        "langues_suivies": ["anglais", "espagnol"],
        "langues_possibles": ["anglais", "espagnol", "chinois", "allemand"],
    }

    assert a_garder(espagnol, reglages)[0]

    garde, motif = a_garder(espagnol, {**reglages, "alternance": True})
    assert not garde
    assert "alternance" in motif
