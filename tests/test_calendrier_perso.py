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


# -------------------------------------------------------------------------
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

    # COL-16 : sans ce rattachement nommé, `appliquer_assignations` donnerait à
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


def test_une_adresse_trop_longue_ne_bloque_pas_la_collecte(client, lorette, thomas):
    # Une adresse complète, sur deux lignes, dépasse les 100 caractères de la
    # colonne : l'insertion échouait et la source cessait de se collecter.
    adresse = ("Chez la famille Martin\\, 12 rue des Exemples\\, bâtiment B escalier 3"
               "\\, 54000 Nancy\\nCode 1234\\, sonner deux fois\\, entrée par la cour")
    flux = _calendrier(("evt-garde@icloud", "Baby-sitting", _demain(15), _demain(18), adresse))

    bilan = client.post("/sources/PERSO_LORETTE/collecter", headers=thomas,
                        params={"texte_ics": flux}).json()
    assert bilan["crees"] == 1

    planning = client.get("/planning", headers=lorette).json()
    garde = next(ligne for ligne in planning if ligne["libelle"] == "Baby-sitting")
    assert len(garde["lieu"]) <= ics.LIEU_MAX
    assert garde["lieu"].startswith("Chez la famille Martin, 12 rue des Exemples")
    assert garde["lieu"].endswith("…") and "\n" not in garde["lieu"]


def test_deux_evenements_qui_se_chevauchent_passent(client, thomas):
    # COL-15 : un calendrier personnel contient souvent un rendez-vous posé sur
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

# ---------------------------------------------------------------------------
# Récurrences
#
# Une application de calendrier écrit « tous les lundis » en une seule ligne.
# L'ADE et Easy at Work, eux, publient chaque séance séparément : le collecteur
# n'avait donc jamais eu à développer quoi que ce soit.
# ---------------------------------------------------------------------------

def _serie(uid: str, resume: str, debut: datetime, fin: datetime,
           regle: str, exceptions: tuple[datetime, ...] = (),
           deplacements: tuple[tuple[datetime, datetime, datetime, str], ...] = ()) -> str:
    """Un flux portant une série, ses exceptions et ses séances déplacées."""
    lignes = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Apple Inc.//iOS 26//FR",
              "BEGIN:VEVENT", f"UID:{uid}", f"SUMMARY:{resume}",
              f"DTSTART;TZID=Europe/Paris:{debut:%Y%m%dT%H%M%S}",
              f"DTEND;TZID=Europe/Paris:{fin:%Y%m%dT%H%M%S}",
              f"RRULE:{regle}"]
    for exception in exceptions:
        lignes.append(f"EXDATE;TZID=Europe/Paris:{exception:%Y%m%dT%H%M%S}")
    lignes.append("END:VEVENT")

    for origine, nouveau_debut, nouvelle_fin, nouveau_resume in deplacements:
        lignes += [
            "BEGIN:VEVENT", f"UID:{uid}", f"SUMMARY:{nouveau_resume}",
            f"RECURRENCE-ID;TZID=Europe/Paris:{origine:%Y%m%dT%H%M%S}",
            f"DTSTART;TZID=Europe/Paris:{nouveau_debut:%Y%m%dT%H%M%S}",
            f"DTEND;TZID=Europe/Paris:{nouvelle_fin:%Y%m%dT%H%M%S}",
            "END:VEVENT",
        ]

    lignes.append("END:VCALENDAR")
    return "\r\n".join(lignes)


def _prochain_lundi(heure: int) -> datetime:
    """Un lundi à venir, pour que les tests ne se périment pas avec le temps."""
    aujourd_hui = datetime.now(PARIS).replace(hour=heure, minute=0, second=0,
                                              microsecond=0)
    return aujourd_hui + timedelta(days=(7 - aujourd_hui.weekday()) % 7 or 7)


def test_une_serie_hebdomadaire_donne_toutes_ses_seances(base):
    # Le point qui manquait : lu littéralement, un cours hebdomadaire n'existe
    # qu'une fois, et les onze autres semaines n'apparaissent nulle part.
    premier = _prochain_lundi(19)
    lues = ics.analyser(
        _serie("danse@icloud", "Cours de danse", premier, premier + timedelta(hours=2),
               "FREQ=WEEKLY;BYDAY=MO;COUNT=12"),
        profil="perso")

    assert len(lues) == 12
    assert lues[0].debut == premier
    assert lues[-1].debut == premier + timedelta(weeks=11)


def test_chaque_occurrence_a_sa_propre_cle_externe(base):
    # Sans date dans la clé, les douze séances s'écraseraient en base et il n'en
    # resterait qu'une.
    premier = _prochain_lundi(19)
    lues = ics.analyser(
        _serie("danse@icloud", "Cours de danse", premier, premier + timedelta(hours=2),
               "FREQ=WEEKLY;BYDAY=MO;COUNT=4"),
        profil="perso")

    assert len({seance.cle_externe for seance in lues}) == 4
    assert all(seance.cle_externe.startswith("danse@icloud#") for seance in lues)


def test_une_seance_annulee_ne_revient_pas(base):
    premier = _prochain_lundi(19)
    lues = ics.analyser(
        _serie("danse@icloud", "Cours de danse", premier, premier + timedelta(hours=2),
               "FREQ=WEEKLY;BYDAY=MO;COUNT=4",
               exceptions=(premier + timedelta(weeks=2),)),
        profil="perso")

    assert len(lues) == 3
    assert all(seance.debut != premier + timedelta(weeks=2) for seance in lues)


def test_une_seance_deplacee_garde_sa_nouvelle_heure(base):
    premier = _prochain_lundi(19)
    origine = premier + timedelta(weeks=1)
    lues = ics.analyser(
        _serie("danse@icloud", "Cours de danse", premier, premier + timedelta(hours=2),
               "FREQ=WEEKLY;BYDAY=MO;COUNT=3",
               deplacements=((origine, origine + timedelta(hours=2),
                              origine + timedelta(hours=4), "Cours de danse (décalé)"),)),
        profil="perso")

    assert len(lues) == 3
    decalee = [seance for seance in lues if "décalé" in seance.libelle]
    assert len(decalee) == 1
    assert decalee[0].debut == origine + timedelta(hours=2)
    # L'occurrence d'origine ne doit pas subsister à côté de son remplacement.
    assert all(seance.debut != origine for seance in lues)


# ---------------------------------------------------------------------------
# Journées entières
# ---------------------------------------------------------------------------

def _journee_entiere(uid: str, resume: str, premier_jour: str, lendemain_du_dernier: str) -> str:
    return "\r\n".join([
        "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Apple Inc.//iOS 26//FR",
        "BEGIN:VEVENT", f"UID:{uid}", f"SUMMARY:{resume}",
        f"DTSTART;VALUE=DATE:{premier_jour}",
        f"DTEND;VALUE=DATE:{lendemain_du_dernier}",
        "END:VEVENT", "END:VCALENDAR",
    ])


def test_une_journee_entiere_est_lue_et_signalee(base):
    # Elles étaient jetées en silence. Sur un flux universitaire ça ne se voyait
    # pas ; sur un calendrier personnel, « Week-end en famille » est justement
    # l'information qui compte.
    jour = (datetime.now(PARIS) + timedelta(days=10)).date()
    lendemain = jour + timedelta(days=2)
    lues = ics.analyser(
        _journee_entiere("weekend@icloud", "Week-end en famille",
                         f"{jour:%Y%m%d}", f"{lendemain:%Y%m%d}"),
        profil="perso")

    assert len(lues) == 1
    assert lues[0].journee_entiere is True
    assert lues[0].debut.date() == jour
    # La borne de fin d'une journée entière est exclusive : deux jours pleins.
    assert lues[0].fin.date() == lendemain


# ---------------------------------------------------------------------------
# Deux calendriers pour une personne : les deux comptent         (COL-14, PLA-1)
#
# Lorette n'en tient pas un mais deux, ses cours et ses gardes d'enfants. Le
# risque, en ajoutant le second, était qu'un seul soit lu : les propositions se
# seraient posées sur des heures déjà prises, ce qui ne se voit qu'à l'usage.
# ---------------------------------------------------------------------------

def _collecter(client, entetes, code: str, *evenements) -> None:
    reponse = client.post(f"/sources/{code}/collecter", headers=entetes,
                          params={"texte_ics": _calendrier(*evenements)})
    assert reponse.status_code == 200, reponse.text


def test_les_deux_calendriers_d_une_personne_comptent(client, thomas, lorette):
    """PLA-1 : la disponibilité se calcule sur la somme des calendriers."""
    jour = (datetime.now(PARIS) + timedelta(days=2)).replace(
        hour=0, minute=0, second=0, microsecond=0)
    _collecter(client, lorette, "PERSO_LORETTE",
               ("cours-1@icloud", "Anatomie", jour.replace(hour=9),
                jour.replace(hour=12), "Fac"))
    _collecter(client, lorette, "PERSO_LORETTE_BABYSITTING",
               ("garde-1@icloud", "Garde des enfants", jour.replace(hour=14),
                jour.replace(hour=19), "Chez les Martin"))

    elle = identifiant(client, CLE_LORETTE)
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row) as conn:
        creneaux = conn.execute(
            "SELECT lower(d) AS debut, upper(d) AS fin "
            "  FROM disponibilites(%s, debut_jour(%s::DATE), "
            "                      debut_jour(%s::DATE + 1)) d ORDER BY lower(d)",
            (elle, jour.date(), jour.date()),
        ).fetchall()

    heures = [(c["debut"].astimezone(PARIS).hour, c["fin"].astimezone(PARIS).hour)
              for c in creneaux]
    # Les deux trous sont creusés : celui des cours et celui de la garde.
    assert not [h for h in heures if h[0] <= 10 < h[1]], heures
    assert not [h for h in heures if h[0] <= 16 < h[1]], heures


def test_le_sport_tient_compte_des_deux_calendriers(client, thomas, lorette):
    """Une séance ne se propose pas pendant une garde d'enfants."""
    from api import sport

    jour = (datetime.now(PARIS) + timedelta(days=2)).replace(
        hour=0, minute=0, second=0, microsecond=0)
    _collecter(client, lorette, "PERSO_LORETTE_BABYSITTING",
               ("garde-2@icloud", "Garde des enfants", jour.replace(hour=16),
                jour.replace(hour=22), "Chez les Martin"))

    elle = identifiant(client, CLE_LORETTE)
    salle = sport.lieu_par_nom("salle")["id_lieu"]
    with psycopg.connect(_url()) as conn:
        def obstacle(heure: int):
            return conn.execute("SELECT obstacle_seance(%s, %s, %s)",
                                (elle, salle, jour.replace(hour=heure))).fetchone()[0]

        assert "Garde des enfants" in obstacle(18)
        assert obstacle(10) is None


def test_une_garde_d_enfants_empeche_la_seance_a_deux(client, thomas, lorette):
    """SPT-30 : « à deux » se calcule sur tous les calendriers de l'autre."""
    from api import sport

    jour = (datetime.now(PARIS) + timedelta(days=2)).replace(
        hour=0, minute=0, second=0, microsecond=0)
    moi = identifiant(client, CLE_THOMAS)
    salle = sport.lieu_par_nom("salle")["id_lieu"]
    debut = jour.replace(hour=18)
    assert sport.possible_a_deux(moi, salle, debut), "libre au départ"

    _collecter(client, lorette, "PERSO_LORETTE_BABYSITTING",
               ("garde-3@icloud", "Garde des enfants", jour.replace(hour=16),
                jour.replace(hour=22), "Chez les Martin"))

    assert sport.possible_a_deux(moi, salle, debut) is False


def test_un_cours_annule_quitte_le_planning(client, thomas):
    """COL-22 : annulé dans le flux, retiré du planning et du calendrier.

    C'est le cas réel : le cours reste publié, marqué annulé, et la collecte
    répondait « rien n'a changé » en le laissant au planning.
    """
    jour = (datetime.now(PARIS) + timedelta(days=3)).replace(
        hour=0, minute=0, second=0, microsecond=0)
    evenements = (("cours-a@icloud", "CM Compilation", jour.replace(hour=8),
                   jour.replace(hour=10), "Amphi"),
                  ("cours-b@icloud", "TD Algo IA", jour.replace(hour=14),
                   jour.replace(hour=16), "223"))
    _collecter(client, thomas, "PERSO_THOMAS", *evenements)

    moi = identifiant(client, CLE_THOMAS)
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row) as conn:
        avant = conn.execute(
            "SELECT count(*) AS n FROM occupation WHERE id_utilisateur = %s "
            "  AND cle_externe LIKE 'cours-%%'", (moi,)).fetchone()["n"]
    assert avant == 2

    # Le TD est décommandé : il reste dans le flux, marqué annulé.
    flux = _calendrier(*evenements).replace(
        "UID:cours-b@icloud", "UID:cours-b@icloud\r\nSTATUS:CANCELLED")
    reponse = client.post("/sources/PERSO_THOMAS/collecter", headers=thomas,
                          params={"texte_ics": flux})

    assert reponse.status_code == 200
    assert reponse.json()["annules"] == 1
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row) as conn:
        restantes = conn.execute(
            "SELECT libelle FROM occupation WHERE id_utilisateur = %s "
            "  AND cle_externe LIKE 'cours-%%'", (moi,)).fetchall()
    assert [o["libelle"] for o in restantes] == ["CM Compilation"]
