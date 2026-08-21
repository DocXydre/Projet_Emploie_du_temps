"""Aller à Saint-Dié : fenêtres, horaires, et le ménage qui suit.

Aucun de ces tests ne touche au réseau. La réponse de la SNCF est injectée,
exactement comme les flux iCalendar le sont ailleurs — sinon la suite
dépendrait d'un jeton, d'une connexion, et des horaires du jour.

Ce qui se vérifie ici tient en une phrase : un train qu'on ne peut pas
attraper n'est pas une proposition, et un aller-retour retenu doit se traduire
en un appartement qu'on ne nettoie pas pendant qu'on n'y est pas.
"""

import json
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

import psycopg
import pytest

from api import trajets as service
from api.collecteurs import sncf
from api.collecteurs.sncf import TrajetImpossible
from api.config import configuration
from tests.conftest import _url

PARIS = ZoneInfo("Europe/Paris")
EXEMPLE = json.loads((Path(__file__).parent / "exemple_sncf.json").read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------
# Fabrication d'une réponse SNCF
# ---------------------------------------------------------------------------

def _navitia(*horaires) -> dict:
    """Réponse Navitia synthétique. `horaires` : (départ, arrivée, changements)."""
    journeys = []
    for depart, arrivee, changements in horaires:
        sections = []
        etapes = ["Lunéville", "Épinal"][:changements] + ["Saint-Dié-des-Vosges"]
        precedent = "Nancy-Ville"
        for etape in etapes:
            sections.append({
                "type": "public_transport",
                "display_informations": {"commercial_mode": "TER"},
                "from": {"name": f"{precedent} ({precedent})"},
                "to": {"name": f"{etape} ({etape})"},
            })
            precedent = etape

        journeys.append({
            "departure_date_time": depart.astimezone(PARIS).strftime("%Y%m%dT%H%M%S"),
            "arrival_date_time": arrivee.astimezone(PARIS).strftime("%Y%m%dT%H%M%S"),
            "nb_transfers": changements,
            "sections": sections,
        })
    return {"journeys": journeys}


# ---------------------------------------------------------------------------
# Lecture d'une réponse SNCF
# ---------------------------------------------------------------------------

def test_une_reponse_reelle_se_lit(base):
    lus = sncf.analyser(EXEMPLE)

    # Trois itinéraires dans le fichier, dont un entièrement à pied.
    assert len(lus) == 2
    assert lus[0].depart == datetime(2026, 8, 28, 18, 12, tzinfo=PARIS)
    assert lus[0].arrivee == datetime(2026, 8, 28, 19, 47, tzinfo=PARIS)
    assert lus[0].duree == timedelta(minutes=95)


def test_un_itineraire_a_pied_n_est_pas_un_trajet(base):
    # Navitia propose de faire Nancy–Saint-Dié à pied en sept heures et demie.
    # C'est une réponse valide, ce n'est pas une proposition.
    assert all(t.correspondances >= 0 for t in sncf.analyser(EXEMPLE))
    assert not any(t.duree > timedelta(hours=6) for t in sncf.analyser(EXEMPLE))


def test_le_resume_dit_ou_l_on_change(base):
    direct, avec_changement = sncf.analyser(EXEMPLE)

    assert direct.resume == "TER direct"
    # Deux trajets de même durée ne se valent pas : changer à Lunéville
    # à 22 h ou passer direct n'est pas la même soirée.
    assert "Lunéville" in avec_changement.resume
    assert "1 correspondance" in avec_changement.resume


def test_une_erreur_sncf_est_remontee_telle_quelle(base):
    charge = {"error": {"id": "no_solution", "message": "no solution found"}}
    with pytest.raises(TrajetImpossible) as erreur:
        sncf.analyser(charge)
    assert erreur.value.code == "no_solution"


def test_sans_jeton_on_le_dit_au_lieu_d_appeler(base):
    conf = configuration()
    assert not conf.sncf_token, "les tests ne doivent pas porter de jeton"
    with pytest.raises(TrajetImpossible) as erreur:
        sncf.interroger("a", "b", datetime.now(PARIS))
    assert erreur.value.code == "jeton_absent"


def _demain(heure: int = 18) -> datetime:
    # À la minute pleine : Navitia ne transporte pas les secondes, et un
    # départ comparé à lui-même échouerait pour trois cent millisecondes.
    return (datetime.now(PARIS) + timedelta(days=1)).replace(
        hour=heure, minute=0, second=0, microsecond=0)


def test_un_train_deja_parti_n_est_pas_propose(base):
    depart = _demain()
    charge = _navitia(
        (depart, depart + timedelta(minutes=95), 0),
        (depart + timedelta(hours=2), depart + timedelta(hours=4), 1),
    )

    retenus = sncf.chercher("NANCY", "SAINT_DIE",
                            pas_avant=depart + timedelta(hours=1), charge=charge)
    assert len(retenus) == 1
    assert retenus[0].correspondances == 1


def test_un_train_qui_arrive_trop_tard_n_est_pas_propose(base):
    depart = _demain()
    charge = _navitia(
        (depart, depart + timedelta(minutes=95), 0),
        (depart, depart + timedelta(hours=5), 1),
    )

    retenus = sncf.chercher("NANCY", "SAINT_DIE", pas_avant=depart,
                            arrive_avant=depart + timedelta(hours=2), charge=charge)
    assert len(retenus) == 1
    assert retenus[0].correspondances == 0


# ---------------------------------------------------------------------------
# Fenêtres de départ
# ---------------------------------------------------------------------------

@pytest.fixture
def horizon_court():
    """Douze jours d'horizon : de quoi contenir deux week-ends, pas plus."""
    conf = configuration()
    ancien = conf.horizon_trajets_jours
    conf.horizon_trajets_jours = 12
    yield 12
    conf.horizon_trajets_jours = ancien


def _minuit(dans_jours: int) -> datetime:
    return (datetime.now(PARIS) + timedelta(days=dans_jours)).replace(
        hour=0, minute=0, second=0, microsecond=0)


def _semaine_chargee(client, entete, libres: set[int], fin_veille=(17, 35),
                     debut_reprise=(8, 0)) -> None:
    """Remplit chaque journée de l'horizon, sauf celles qu'on veut libres.

    Sans ce remplissage, tout l'horizon serait un seul creux et il n'y aurait
    rien à choisir : les fenêtres n'existent que par contraste.
    """
    for jour in range(0, 13):
        if jour in libres:
            continue

        debut = _minuit(jour).replace(hour=8)
        fin = _minuit(jour).replace(hour=20)
        # La veille d'un départ, le dernier cours s'arrête plus tôt : c'est
        # cette heure-là qui commande le premier train attrapable.
        if jour + 1 in libres:
            fin = _minuit(jour).replace(hour=fin_veille[0], minute=fin_veille[1])
        # Au retour, c'est le premier cours qui commande le dernier train.
        if jour - 1 in libres:
            debut = _minuit(jour).replace(hour=debut_reprise[0],
                                          minute=debut_reprise[1])

        reponse = client.post("/occupations", headers=entete, json={
            "type": "cours", "libelle": f"Cours J+{jour}",
            "debut": debut.isoformat(), "fin": fin.isoformat(),
        })
        assert reponse.status_code in (200, 201), reponse.text


def test_une_fenetre_commence_a_la_fin_du_dernier_cours(client, thomas, horizon_court):
    _semaine_chargee(client, thomas, libres={5, 6})

    creneaux = service.fenetres(1)
    assert len(creneaux) == 1

    fenetre = creneaux[0]
    assert fenetre["debut"].astimezone(PARIS).hour == 17
    assert fenetre["debut"].astimezone(PARIS).minute == 35
    assert fenetre["fin"].astimezone(PARIS).hour == 8
    # Deux journées entières plus les deux bouts.
    assert fenetre["duree"] >= timedelta(hours=48)


def test_le_premier_train_se_prend_trente_minutes_apres(client, thomas, horizon_court):
    _semaine_chargee(client, thomas, libres={5, 6})
    fenetre = service.fenetres(1)[0]

    # R64 : le temps d'aller à la gare. Sans cette marge, le système
    # proposerait un train qu'on regarde partir depuis l'amphi.
    assert fenetre["depart_au_plus_tot"] - fenetre["debut"] == timedelta(minutes=30)
    assert fenetre["fin"] - fenetre["retour_au_plus_tard"] == timedelta(minutes=30)


def test_un_creux_trop_court_n_est_pas_une_fenetre(client, thomas, horizon_court):
    # Un seul jour libre : vingt-quatre heures plus deux bouts, pas assez pour
    # que deux heures et demie de train dans chaque sens se justifient.
    _semaine_chargee(client, thomas, libres={5})
    assert service.fenetres(1) == []


def test_une_absence_deja_declaree_retire_la_fenetre(client, thomas, horizon_court):
    _semaine_chargee(client, thomas, libres={5, 6})
    fenetre = service.fenetres(1)[0]

    client.post("/absences", headers=thomas, json={
        "debut": fenetre["debut"].isoformat(),
        "fin": fenetre["fin"].isoformat(),
        "lieu": "Saint-Dié",
    })

    # Proposer un aller pour un week-end où l'on est déjà parti n'aurait
    # aucun sens.
    assert service.fenetres(1) == []


def test_les_taches_menageres_n_empechent_pas_de_partir(client, thomas, horizon_court):
    _semaine_chargee(client, thomas, libres={5, 6})
    client.post("/planning/placer", headers=thomas)

    # Un créneau de ménage posé samedi ne doit pas fermer la fenêtre : c'est
    # justement ce que l'absence est censée déplacer.
    assert len(service.fenetres(1)) == 1


# ---------------------------------------------------------------------------
# Propositions
# ---------------------------------------------------------------------------

def _aller_type(fenetre, decalage_heures=1.0, changements=0):
    depart = fenetre["depart_au_plus_tot"] + timedelta(hours=decalage_heures)
    return (depart, depart + timedelta(minutes=95), changements)


def test_proposer_un_aller_enregistre_les_horaires(client, thomas, horizon_court):
    _semaine_chargee(client, thomas, libres={5, 6})
    fenetre = service.fenetres(1)[0]

    charge = _navitia(_aller_type(fenetre, 0.5), _aller_type(fenetre, 2, 1))
    resultat = service.proposer_aller(1, rang=1, charge=charge)

    assert len(resultat["trajets"]) == 2
    assert resultat["trajets"][0]["depart"] >= fenetre["depart_au_plus_tot"]
    assert all(t["sens"] == "aller" for t in resultat["trajets"])


def test_un_train_avant_la_fin_des_cours_est_ecarte(client, thomas, horizon_court):
    _semaine_chargee(client, thomas, libres={5, 6})
    fenetre = service.fenetres(1)[0]

    trop_tot = fenetre["debut"] + timedelta(minutes=10)
    charge = _navitia((trop_tot, trop_tot + timedelta(minutes=95), 0),
                      _aller_type(fenetre, 1))

    resultat = service.proposer_aller(1, rang=1, charge=charge)
    assert len(resultat["trajets"]) == 1
    assert resultat["trajets"][0]["depart"] > fenetre["debut"]


def test_un_rang_inexistant_ne_propose_rien(client, thomas, horizon_court):
    _semaine_chargee(client, thomas, libres={5, 6})
    resultat = service.proposer_aller(1, rang=7, charge=_navitia())
    assert resultat["fenetre"] is None
    assert resultat["trajets"] == []


def test_le_retour_ne_part_pas_dans_la_foulee(client, thomas, horizon_court):
    _semaine_chargee(client, thomas, libres={5, 6})
    fenetre = service.fenetres(1)[0]

    aller = service.proposer_aller(1, 1, charge=_navitia(_aller_type(fenetre)))["trajets"][0]

    juste_apres = aller["arrivee"] + timedelta(hours=1)
    lendemain = aller["arrivee"] + timedelta(hours=20)
    charge = _navitia((juste_apres, juste_apres + timedelta(minutes=95), 0),
                      (lendemain, lendemain + timedelta(minutes=95), 0))

    resultat = service.proposer_retour(aller["id_trajet"], charge=charge)
    # Rester une heure à Saint-Dié n'est pas un séjour.
    assert len(resultat["trajets"]) == 1
    assert resultat["trajets"][0]["depart"] == lendemain


def test_le_retour_propose_les_derniers_trains(client, thomas, horizon_court):
    _semaine_chargee(client, thomas, libres={5, 6})
    fenetre = service.fenetres(1)[0]
    aller = service.proposer_aller(1, 1, charge=_navitia(_aller_type(fenetre)))["trajets"][0]

    limite = fenetre["retour_au_plus_tard"]
    # Six retours possibles, espacés de deux heures, le dernier arrivant pile
    # à l'heure limite.
    candidats = [(limite - timedelta(hours=2 * n, minutes=95),
                  limite - timedelta(hours=2 * n), 0)
                 for n in range(6)]

    resultat = service.proposer_retour(aller["id_trajet"], charge=_navitia(*candidats))
    departs = [t["depart"] for t in resultat["trajets"]]

    assert len(departs) == 4
    # R71 : le premier proposé est le dernier train. Chaque heure gagnée est
    # une heure de plus sur place — proposer les premiers retours reviendrait
    # à proposer d'écourter le séjour.
    assert departs[0] == limite - timedelta(minutes=95)
    assert departs == sorted(departs, reverse=True)


def test_les_retours_ecartes_sont_les_plus_matinaux(client, thomas, horizon_court):
    _semaine_chargee(client, thomas, libres={5, 6})
    fenetre = service.fenetres(1)[0]
    aller = service.proposer_aller(1, 1, charge=_navitia(_aller_type(fenetre)))["trajets"][0]

    limite = fenetre["retour_au_plus_tard"]
    candidats = [(limite - timedelta(hours=2 * n, minutes=95),
                  limite - timedelta(hours=2 * n), 0)
                 for n in range(6)]

    resultat = service.proposer_retour(aller["id_trajet"], charge=_navitia(*candidats))
    proposes = {t["depart"] for t in resultat["trajets"]}

    # Ceux qu'on ne montre pas sont les deux plus tôt, pas les deux plus tard.
    assert limite - timedelta(hours=10, minutes=95) not in proposes
    assert limite - timedelta(hours=8, minutes=95) not in proposes


def test_on_interroge_la_sncf_par_heure_d_arrivee_pour_un_retour(base):
    quand = datetime(2026, 8, 31, 7, 30, tzinfo=PARIS)

    aller = sncf.parametres("a", "b", quand)
    retour = sncf.parametres("a", "b", quand, "arrival")

    assert aller["datetime_represents"] == "departure"
    # Sans cela, on demanderait les premiers trains après une heure donnée :
    # ceux du soir ne remonteraient jamais.
    assert retour["datetime_represents"] == "arrival"
    assert retour["datetime"] == "20260831T073000"


def test_chercher_le_dernier_train_suppose_une_heure_limite(base):
    with pytest.raises(TrajetImpossible) as erreur:
        sncf.chercher("NANCY", "SAINT_DIE", pas_avant=datetime.now(PARIS),
                      au_plus_tard=True)
    assert erreur.value.code == "sans_borne"


def test_avec_un_cours_a_16h30_on_propose_le_train_de_14h42(client, thomas, horizon_court):
    """Le cas tel que Thomas le décrit, chiffres compris.

    Cours à 16h30, trente minutes pour rentrer de la gare : il faut être
    arrivé à 16h00. Le train de 14h42 arrive pile, celui de 15h30 arrive trop
    tard, et celui du matin fait perdre une demi-journée pour rien.
    """
    _semaine_chargee(client, thomas, libres={5, 6}, debut_reprise=(16, 30))
    fenetre = service.fenetres(1)[0]

    reprise = fenetre["fin"].astimezone(PARIS)
    assert (reprise.hour, reprise.minute) == (16, 30)
    limite = fenetre["retour_au_plus_tard"].astimezone(PARIS)
    assert (limite.hour, limite.minute) == (16, 0)

    aller = service.proposer_aller(1, 1, charge=_navitia(_aller_type(fenetre)))["trajets"][0]
    jour = _minuit(7)
    horaires = {
        "10h05": (jour.replace(hour=10, minute=5), jour.replace(hour=11, minute=40)),
        "14h42": (jour.replace(hour=14, minute=42), jour.replace(hour=16, minute=0)),
        "15h30": (jour.replace(hour=15, minute=30), jour.replace(hour=16, minute=48)),
    }
    charge = _navitia(*[(d, a, 0) for d, a in horaires.values()])

    resultat = service.proposer_retour(aller["id_trajet"], charge=charge)
    proposes = [t["depart"].astimezone(PARIS) for t in resultat["trajets"]]

    assert proposes[0] == horaires["14h42"][0]
    # Celui de 15h30 arriverait à 16h48 : dix-huit minutes après le cours.
    assert horaires["15h30"][0] not in proposes


def test_le_retour_doit_ramener_avant_le_premier_cours(client, thomas, horizon_court):
    _semaine_chargee(client, thomas, libres={5, 6})
    fenetre = service.fenetres(1)[0]
    aller = service.proposer_aller(1, 1, charge=_navitia(_aller_type(fenetre)))["trajets"][0]

    trop_tard = fenetre["fin"] - timedelta(minutes=10)
    a_temps = fenetre["retour_au_plus_tard"] - timedelta(hours=2)
    charge = _navitia((trop_tard - timedelta(minutes=95), trop_tard, 0),
                      (a_temps - timedelta(minutes=95), a_temps, 0))

    resultat = service.proposer_retour(aller["id_trajet"], charge=charge)
    assert len(resultat["trajets"]) == 1
    assert resultat["trajets"][0]["arrivee"] <= fenetre["retour_au_plus_tard"]


# ---------------------------------------------------------------------------
# Retenir, et ce que ça change
# ---------------------------------------------------------------------------

def _aller_retour(client, thomas):
    fenetre = service.fenetres(1)[0]
    aller = service.proposer_aller(1, 1, charge=_navitia(
        _aller_type(fenetre, 0.5), _aller_type(fenetre, 3, 1)))["trajets"][0]

    depart_retour = fenetre["retour_au_plus_tard"] - timedelta(hours=3)
    retour = service.proposer_retour(aller["id_trajet"], charge=_navitia(
        (depart_retour, depart_retour + timedelta(minutes=95), 0)))["trajets"][0]
    return fenetre, aller, retour


def test_retenir_declare_l_absence(client, thomas, horizon_court):
    _semaine_chargee(client, thomas, libres={5, 6})
    fenetre, aller, retour = _aller_retour(client, thomas)

    resultat = service.retenir(aller["id_trajet"], retour["id_trajet"])
    absence = resultat["absence"]

    assert absence["debut"] == aller["depart"]
    assert absence["fin"] == retour["arrivee"]
    assert absence["lieu"] == "Saint-Dié-des-Vosges"


def test_retenir_gele_le_menage_des_jours_couverts(client, thomas, horizon_court):
    _semaine_chargee(client, thomas, libres={5, 6})
    client.post("/planning/placer", headers=thomas)
    fenetre, aller, retour = _aller_retour(client, thomas)

    service.retenir(aller["id_trajet"], retour["id_trajet"])

    # La journée entièrement couverte par l'absence : Thomas n'y salit rien,
    # il n'a donc rien à y nettoyer.
    couverte = (aller["depart"].astimezone(PARIS) + timedelta(days=1)).date()
    planning = client.get("/planning", headers=thomas).json()
    ce_jour_la = [ligne for ligne in planning
                  if ligne["nature"] == "tache"
                  and ligne["debut"].startswith(couverte.isoformat())]

    assert [t for t in ce_jour_la if t["id_utilisateur"] == 1] == []
    # R59 : ce qui reste revient à Lorette, qui, elle, est là. L'appartement
    # ne se nettoie pas tout seul sous prétexte que l'un des deux est parti.
    assert all(t["id_utilisateur"] == 2 for t in ce_jour_la)


def test_retenir_ecarte_les_autres_horaires(client, thomas, horizon_court):
    _semaine_chargee(client, thomas, libres={5, 6})
    fenetre, aller, retour = _aller_retour(client, thomas)

    service.retenir(aller["id_trajet"], retour["id_trajet"])

    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row) as conn:
        statuts = conn.execute(
            "SELECT statut, count(*) AS n FROM trajet GROUP BY statut ORDER BY statut"
        ).fetchall()

    compte = {ligne["statut"]: ligne["n"] for ligne in statuts}
    assert compte["retenue"] == 2
    # Le second horaire d'aller proposé n'a plus lieu d'être, mais on le garde :
    # relire ce qui avait été proposé aide à comprendre un choix, plus tard.
    assert compte["ecartee"] == 1


def test_un_aller_sans_retour_gele_jusqu_au_prochain_cours(client, thomas, horizon_court):
    _semaine_chargee(client, thomas, libres={5, 6})
    fenetre = service.fenetres(1)[0]
    aller = service.proposer_aller(1, 1, charge=_navitia(_aller_type(fenetre)))["trajets"][0]

    resultat = service.retenir(aller["id_trajet"], None)

    # R69 : partir sans savoir quand on rentre est un cas ordinaire.
    assert resultat["absence"]["fin"] == fenetre["fin"]
    assert "à fixer" in resultat["absence"]["commentaire"]


def test_un_retour_avant_l_arrivee_est_refuse(client, thomas, horizon_court):
    _semaine_chargee(client, thomas, libres={5, 6})
    fenetre = service.fenetres(1)[0]
    aller = service.proposer_aller(1, 1, charge=_navitia(_aller_type(fenetre, 3)))["trajets"][0]

    # On fabrique un retour antérieur à l'aller, ce que la conversation
    # n'autorise pas mais qu'un appel direct à l'API pourrait tenter.
    avant = fenetre["debut"] + timedelta(hours=1)
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row, autocommit=True) as conn:
        id_retour = conn.execute(
            """
            INSERT INTO trajet (id_utilisateur, sens, periode, origine, destination,
                                id_trajet_aller)
            VALUES (1, 'retour', tstzrange(%s, %s, '[)'), 'Saint-Dié', 'Nancy', %s)
            RETURNING id_trajet
            """,
            (avant, avant + timedelta(minutes=95), aller["id_trajet"]),
        ).fetchone()["id_trajet"]

    with pytest.raises(psycopg.Error) as erreur:
        service.retenir(aller["id_trajet"], id_retour)
    assert "avant l'arrivée" in erreur.value.diag.message_primary


def test_partir_deux_fois_le_meme_week_end_est_refuse(client, thomas, horizon_court):
    _semaine_chargee(client, thomas, libres={5, 6})
    fenetre, aller, retour = _aller_retour(client, thomas)
    service.retenir(aller["id_trajet"], retour["id_trajet"])

    autre = service.proposer_aller(1, 1, charge=_navitia(_aller_type(fenetre, 2)))
    # La fenêtre a disparu puisque l'absence la couvre : il n'y a plus rien
    # à proposer, et c'est la bonne réponse.
    assert autre["fenetre"] is None


def test_annuler_un_trajet_rend_les_jours_au_menage(client, thomas, horizon_court):
    _semaine_chargee(client, thomas, libres={5, 6})
    fenetre, aller, retour = _aller_retour(client, thomas)
    resultat = service.retenir(aller["id_trajet"], retour["id_trajet"])

    service.oublier(resultat["absence"]["id_absence"])

    assert client.get("/absences", headers=thomas).json() == []
    # La fenêtre est de nouveau disponible : le voyage n'a pas eu lieu.
    assert len(service.fenetres(1)) == 1


def test_les_trajets_retenus_se_listent(client, thomas, horizon_court):
    _semaine_chargee(client, thomas, libres={5, 6})
    fenetre, aller, retour = _aller_retour(client, thomas)
    service.retenir(aller["id_trajet"], retour["id_trajet"])

    retenus = service.trajets_retenus(1)
    assert [t["sens"] for t in retenus] == ["aller", "retour"]
    assert retenus[0]["destination"] == "Saint-Dié-des-Vosges"


# ---------------------------------------------------------------------------
# Ce que le bot affiche
# ---------------------------------------------------------------------------

def test_une_fenetre_se_resume_en_une_ligne(client, thomas, horizon_court):
    _semaine_chargee(client, thomas, libres={5, 6})
    texte = service.resumer_fenetre(service.fenetres(1)[0])

    assert "17h35" in texte
    assert "08h00" in texte
    assert "h)" in texte  # la durée, pour juger d'un coup d'œil


def test_une_fenetre_sans_rien_apres_le_dit(client, thomas, horizon_court):
    # Rien n'est collecté au-delà de J+6 : affirmer une heure de retour limite
    # serait inventer une contrainte qui n'existe pas.
    _semaine_chargee(client, thomas, libres={5, 6, 7, 8, 9, 10, 11, 12})
    texte = service.resumer_fenetre(service.fenetres(1)[0])
    assert "rien après" in texte


def test_le_bouton_retour_retrouve_son_aller(client, thomas, horizon_court):
    from api.bot import _aller_du_retour

    _semaine_chargee(client, thomas, libres={5, 6})
    fenetre, aller, retour = _aller_retour(client, thomas)

    # C'est ce qui permet au bouton de ne porter qu'un seul identifiant :
    # Telegram limite la donnée de rappel à soixante-quatre octets.
    assert _aller_du_retour(retour["id_trajet"]) == aller["id_trajet"]


def test_un_retour_orphelin_ne_valide_rien(client, thomas, horizon_court):
    from api.bot import _aller_du_retour

    with pytest.raises(ValueError):
        _aller_du_retour(999999)


# ---------------------------------------------------------------------------
# Parcours par l'API
# ---------------------------------------------------------------------------

def test_le_parcours_complet_par_l_api(client, thomas, horizon_court):
    _semaine_chargee(client, thomas, libres={5, 6})

    fenetres = client.get("/trajets/fenetres", headers=thomas).json()
    assert len(fenetres) == 1

    fenetre = service.fenetres(1)[0]
    aller = client.post("/trajets/aller", headers=thomas, params={"rang": 1},
                        json=_navitia(_aller_type(fenetre))).json()["trajets"][0]

    depart_retour = fenetre["retour_au_plus_tard"] - timedelta(hours=3)
    retour = client.post(
        "/trajets/retour", headers=thomas, params={"aller": aller["id_trajet"]},
        json=_navitia((depart_retour, depart_retour + timedelta(minutes=95), 0)),
    ).json()["trajets"][0]

    cree = client.post("/trajets/retenir", headers=thomas, json={
        "id_aller": aller["id_trajet"], "id_retour": retour["id_trajet"]})
    assert cree.status_code == 201

    assert len(client.get("/trajets", headers=thomas).json()) == 2


def test_sans_jeton_l_api_le_dit_sans_planter(client, thomas, horizon_court):
    _semaine_chargee(client, thomas, libres={5, 6})

    # Aucune charge injectée : le client SNCF est réellement sollicité, et
    # s'arrête faute de jeton. C'est un 503, pas un 500.
    reponse = client.post("/trajets/aller", headers=thomas, params={"rang": 1})
    assert reponse.status_code == 503
    assert reponse.json()["code"] == "jeton_absent"
