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

    # WKD-2 : rejouée le lendemain, la ronde ne doit rien créer de neuf.
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

def test_un_week_end_lointain_s_affiche_sans_rien_dire(client, thomas):
    """WKD-7 : repérer n'est pas annoncer.

    À douze jours, la question ne se pose pas encore. Le creux s'inscrit au
    calendrier pour qu'on l'ait en tête, et se tait.
    """
    _occuper(client, thomas, {12, 13})

    bilan = propositions.tour_de_ronde(1)

    assert bilan["proposees"] == 1
    assert bilan["annoncees"] == 0
    assert notifications() == []
    # Mais elle est bien là, visible dans le planning.
    assert len(propositions.en_attente(1)) == 1


def test_a_une_semaine_il_en_parle(client, thomas):
    _occuper(client, thomas, {6, 7})

    bilan = propositions.tour_de_ronde(1)

    assert bilan["annoncees"] == 1
    envoyees = notifications()
    assert len(envoyees) == 1
    assert "Week-end libre repéré" in envoyees[0]["contenu"]
    assert "Lusse" in envoyees[0]["contenu"]


def test_la_ronde_du_lendemain_se_tait(client, thomas):
    _occuper(client, thomas, {6, 7})
    propositions.tour_de_ronde(1)

    seconde = propositions.tour_de_ronde(1)

    assert (seconde["proposees"], seconde["annoncees"]) == (0, 0)
    assert len(notifications()) == 1


def test_un_week_end_repere_tot_parle_le_moment_venu(client, thomas):
    """La proposition attend son tour, puis s'annonce une seule fois."""
    _occuper(client, thomas, {12, 13})
    propositions.tour_de_ronde(1)
    assert notifications() == []

    # Six jours passent : le départ entre dans le délai d'annonce. Tout
    # l'emploi du temps glisse avec la proposition, sans quoi elle tomberait
    # sur des cours et serait retirée, à juste titre (WKD-9).
    with psycopg.connect(_url(), autocommit=True) as conn:
        conn.execute("UPDATE proposition "
                     "   SET periode = tstzrange(lower(periode) - INTERVAL '6 days', "
                     "                           upper(periode) - INTERVAL '6 days')")
        conn.execute("DELETE FROM occupation")
    _occuper(client, thomas, {6, 7})

    assert propositions.tour_de_ronde(1)["annoncees"] == 1
    assert len(notifications()) == 1
    # Et pas deux fois.
    assert propositions.tour_de_ronde(1)["annoncees"] == 0
    assert len(notifications()) == 1


def _hier(champ: str = "annoncee_le") -> None:
    """Fait comme si l'annonce datait de la veille."""
    with psycopg.connect(_url(), autocommit=True) as conn:
        conn.execute(f"UPDATE proposition SET {champ} = now() - INTERVAL '1 day'")


def test_la_relance_est_coupee_par_defaut(client, thomas):
    # Deux week-ends dans la fenêtre faisaient quatre messages pour une seule
    # question. Une annonce suffit.
    _occuper(client, thomas, {2, 3})
    propositions.tour_de_ronde(1)
    _hier()

    assert propositions.tour_de_ronde(1)["relancees"] == 0
    assert len(notifications()) == 1


def test_la_relance_rallumee_arrive_a_trois_jours(client, thomas):
    from api.config import configuration

    conf = configuration()
    ancien = conf.proposition_relance_jours
    conf.proposition_relance_jours = 3
    try:
        _occuper(client, thomas, {2, 3})
        propositions.tour_de_ronde(1)
        _hier()

        seconde = propositions.tour_de_ronde(1)
        assert seconde["relancees"] == 1

        envoyees = notifications()
        assert len(envoyees) == 2
        assert "Ça approche" in envoyees[1]["contenu"]

        # WKD-5 : une seule, jamais deux.
        assert propositions.tour_de_ronde(1)["relancees"] == 0
    finally:
        conf.proposition_relance_jours = ancien


def test_un_week_end_decline_ne_revient_pas(client, thomas):
    _occuper(client, thomas, {2, 3})
    propositions.tour_de_ronde(1)
    proposee = propositions.en_attente(1)[0]

    propositions.ecarter(proposee["id_proposition"])
    _hier()

    # WKD-4 : ni nouvelle proposition, ni annonce.
    apres = propositions.tour_de_ronde(1)
    assert (apres["proposees"], apres["annoncees"], apres["relancees"]) == (0, 0, 0)
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


# ---------------------------------------------------------------------------
# Une proposition se revérifie                                  WKD-9, WKD-10
#
# Elle était calculée une fois puis laissée telle quelle : un cours ajouté le
# vendredi matin laissait au calendrier un week-end commençant le jeudi soir.
# Aucun de ces tests ne relance le placement ni la ronde : c'est l'écriture de
# l'occupation elle-même qui déclenche la vérification.
# ---------------------------------------------------------------------------

def _cours(client, entete, jour: int, debut=(8, 30), fin=(12, 0),
           libelle: str = "CM Gestion de production") -> dict:
    reponse = client.post("/occupations", headers=entete, json={
        "type": "cours", "libelle": libelle,
        "debut": _minuit(jour).replace(hour=debut[0], minute=debut[1]).isoformat(),
        "fin": _minuit(jour).replace(hour=fin[0], minute=fin[1]).isoformat(),
    })
    assert reponse.status_code == 201, reponse.text
    return reponse.json()


def _alertes() -> list[str]:
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row) as conn:
        return [ligne["contenu"] for ligne in conn.execute(
            "SELECT contenu FROM notification WHERE type = 'alerte' "
            " ORDER BY id_notification").fetchall()]


def _envoyer_la_file() -> None:
    """Fait comme si le bot avait tout transmis."""
    with psycopg.connect(_url(), autocommit=True) as conn:
        conn.execute("UPDATE notification SET statut = 'envoyee', date_envoi = now() "
                     " WHERE statut = 'a_envoyer'")


def test_un_cours_ajoute_raccourcit_la_proposition(client, thomas):
    _occuper(client, thomas, {12, 13, 14})
    propositions.reperer(1)
    avant = propositions.en_attente(1)[0]

    _cours(client, thomas, 12)

    apres = propositions.en_attente(1)
    assert len(apres) == 1
    # La même proposition, pas une nouvelle : elle garde sa réponse en attente.
    assert apres[0]["id_proposition"] == avant["id_proposition"]
    # Elle commence à la fin du cours, et plus la veille au soir.
    assert apres[0]["debut"] == _minuit(12).replace(hour=12)
    assert apres[0]["fin"] == avant["fin"]


def test_le_calendrier_suit(client, thomas):
    _occuper(client, thomas, {12, 13, 14})
    propositions.reperer(1)
    _cours(client, thomas, 12)

    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row) as conn:
        debut = conn.execute(
            "SELECT debut FROM v_planning WHERE nature = 'proposition'").fetchone()["debut"]

    # C'est ce que le téléphone affiche : le bandeau ne couvre plus la veille.
    assert debut.astimezone(PARIS).date() == _minuit(12).date()


def test_une_proposition_qui_ne_tient_plus_disparait(client, thomas):
    _occuper(client, thomas, {12, 13})
    propositions.reperer(1)
    assert len(propositions.en_attente(1)) == 1

    # Le cours coupe le creux en deux morceaux trop courts pour partir.
    _cours(client, thomas, 12)

    assert propositions.en_attente(1) == []


def test_une_annonce_devenue_fausse_est_corrigee(client, thomas):
    _occuper(client, thomas, {5, 6, 7})
    propositions.tour_de_ronde(1)
    _envoyer_la_file()

    _cours(client, thomas, 5)

    # WKD-10 : on avait dit jeudi soir. Le dire faux sans le corriger serait
    # pire que de ne rien avoir dit.
    alertes = _alertes()
    assert len(alertes) == 2
    assert "a changé" in alertes[1]
    assert "CM Gestion de production" in alertes[1]
    assert f"{_minuit(5):%d/%m} à 12h00" in alertes[1]


def test_une_annonce_pas_encore_partie_est_remplacee(client, thomas):
    _occuper(client, thomas, {5, 6, 7})
    propositions.tour_de_ronde(1)

    _cours(client, thomas, 5)

    # Le premier message n'a jamais été lu : inutile d'en envoyer deux, dont
    # un qui parle de dates qui n'existent plus.
    alertes = _alertes()
    assert len(alertes) == 1
    assert "a changé" in alertes[0]


def test_sans_annonce_rien_a_corriger(client, thomas):
    _occuper(client, thomas, {12, 13, 14})
    propositions.reperer(1)

    _cours(client, thomas, 12)

    # Repérée mais jamais annoncée : le calendrier suffit (WKD-7).
    assert _alertes() == []


def test_une_proposition_annoncee_qui_meurt_le_dit(client, thomas):
    _occuper(client, thomas, {5, 6})
    propositions.tour_de_ronde(1)
    _envoyer_la_file()

    _cours(client, thomas, 5)

    alertes = _alertes()
    assert "ne tient plus" in alertes[-1]
    assert "CM Gestion de production" in alertes[-1]


def test_reverifier_deux_fois_ne_change_rien(client, thomas):
    _occuper(client, thomas, {5, 6, 7})
    propositions.tour_de_ronde(1)
    _envoyer_la_file()
    _cours(client, thomas, 5)
    avant = (propositions.en_attente(1), _alertes())

    client.post("/planning/placer", headers=thomas)
    propositions.tour_de_ronde(1)

    assert (propositions.en_attente(1), _alertes()) == avant


def test_un_cours_annule_n_allonge_pas_la_proposition(client, thomas):
    # À sens unique : un calendrier qui s'étire et se rétracte à chaque
    # collecte ne se lit plus.
    _occuper(client, thomas, {12, 13, 14})
    propositions.reperer(1)
    ajoute = _cours(client, thomas, 12)
    raccourcie = propositions.en_attente(1)[0]

    client.delete(f"/occupations/{ajoute['id_occupation']}", headers=thomas)

    assert propositions.en_attente(1)[0]["debut"] == raccourcie["debut"]


def test_une_occupation_personnelle_ne_touche_a_rien(client, thomas):
    _occuper(client, thomas, {12, 13, 14})
    propositions.reperer(1)
    avant = propositions.en_attente(1)

    # TRJ-1 : seuls les cours et le travail retiennent sur place.
    client.post("/occupations", headers=thomas, json={
        "type": "autre", "libelle": "Coiffeur",
        "debut": _minuit(12).replace(hour=10).isoformat(),
        "fin": _minuit(12).replace(hour=11).isoformat(),
    })

    assert propositions.en_attente(1) == avant
