"""Séances de sport : le lieu a des heures, le trajet compte, la nuit aussi.

HAL propose les séances sur quatre semaines (SPT-33). Ce qui reste ici, ce
sont les règles que toute séance respecte, de HAL, libre, posée à la main ou
acceptée à deux : un lieu a ses heures, le trajet occupe l'agenda, la nuit
laisse dormir, un jour porte au plus deux séances.

L'ancienne organisation, réservations « à déterminer », habitudes et alerte
du lundi, est retirée (lot 2) ; ses tests sont rangés avec son code dans
anciennes_fonctionnalites/reservations_sport/.
"""

from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

import psycopg
import pytest

from api import conversation as conv
from api import sport
from tests.conftest import CLE_THOMAS, _url

PARIS = ZoneInfo("Europe/Paris")


def sql(requete: str, *parametres):
    """Exécute et rend les lignes, ou une liste vide si la requête n'en rend pas."""
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row,
                         autocommit=True) as conn:
        curseur = conn.execute(requete, parametres or None)
        return curseur.fetchall() if curseur.description else []


def un(requete: str, *parametres):
    lignes = sql(requete, *parametres)
    return next(iter(lignes[0].values())) if lignes else None


def identifiant(client, cle: str = CLE_THOMAS) -> int:
    return client.get("/moi", headers={"X-Cle-Api": cle}).json()["id_utilisateur"]


def prochain(jour_semaine: int, dans_au_moins: int = 1) -> date:
    """Prochaine occurrence d'un jour de la semaine (1 = lundi)."""
    jour = datetime.now(PARIS).date() + timedelta(days=dans_au_moins)
    while jour.isoweekday() != jour_semaine:
        jour += timedelta(days=1)
    return jour


def prochain_ouvert(jour_semaine: int) -> date:
    """Idem, mais après la réouverture de la piscine.

    La date de reprise se lit en base plutôt que d'être écrite ici : elle
    changera d'une année sur l'autre, et un test qui la répète devient faux
    sans prévenir.
    """
    reprise = un("""
        SELECT COALESCE(max(upper(f.periode)), CURRENT_DATE)
          FROM fermeture f JOIN lieu_sport l USING (id_lieu)
         WHERE l.code = 'PISCINE_SUAPS'
    """)
    jour = max(reprise, datetime.now(PARIS).date() + timedelta(days=1))
    while jour.isoweekday() != jour_semaine:
        jour += timedelta(days=1)
    return jour


def cours(client, entete, jour: date, debut: time, fin: time) -> None:
    reponse = client.post("/occupations", headers=entete, json={
        "type": "cours", "libelle": "Cours",
        "debut": datetime.combine(jour, debut, PARIS).isoformat(),
        "fin": datetime.combine(jour, fin, PARIS).isoformat(),
    })
    assert reponse.status_code in (200, 201), reponse.text


def seances(client, entete) -> list[dict]:
    return sql("""
        SELECT lower(o.creneau) AS debut, upper(o.creneau) AS fin,
               l.code AS lieu, o.id_utilisateur
          FROM occurrence o
          JOIN tache t ON t.id_tache = o.id_tache
          LEFT JOIN lieu_sport l ON l.id_lieu = o.id_lieu
         WHERE t.categorie = 'sport' AND o.creneau IS NOT NULL
         ORDER BY lower(o.creneau)
    """)


# ---------------------------------------------------------------------------
# Heures d'ouverture
# ---------------------------------------------------------------------------

def test_la_piscine_ouvre_a_midi_en_semaine(base):
    lundi = prochain_ouvert(1)
    plages = sql("SELECT plages_ouvertes((SELECT id_lieu FROM lieu_sport "
                 "WHERE code='PISCINE_SUAPS'), %s) AS p", lundi)
    assert len(plages) == 2


def test_la_piscine_est_fermee_le_dimanche(base):
    dimanche = prochain_ouvert(7)
    plages = sql("SELECT plages_ouvertes((SELECT id_lieu FROM lieu_sport "
                 "WHERE code='PISCINE_SUAPS'), %s) AS p", dimanche)

    # « Aucune plage ce jour-là » n'est pas « ouvert en permanence ». La
    # première version proposait un bain le dimanche à 6h40, porte close.
    assert plages == []


def test_une_fermeture_ferme_le_lieu_malgre_ses_horaires(base):
    lundi = prochain_ouvert(1)
    piscine = un("SELECT id_lieu FROM lieu_sport WHERE code='PISCINE_SUAPS'")
    assert sql("SELECT plages_ouvertes(%s, %s) AS p", piscine, lundi)

    sql("INSERT INTO fermeture (id_lieu, periode, motif) VALUES (%s, %s, %s)",
        piscine, f"[{lundi},{lundi + timedelta(days=7)})", "Vacances de la Toussaint")

    # SPT-3 : les heures d'ouverture disent une semaine type. Elles ne disent
    # rien de l'été ni des vacances — et un SUAPS ferme trois mois par an.
    # Le nettoyage est fait par la fixture, pas par un `finally` : celui-ci ne
    # protège de rien quand c'est l'insertion elle-même qui échoue.
    assert sql("SELECT plages_ouvertes(%s, %s) AS p", piscine, lundi) == []


def test_deux_fermetures_qui_se_chevauchent_sont_refusees(base):
    import pytest

    piscine = un("SELECT id_lieu FROM lieu_sport WHERE code='PISCINE_SUAPS'")
    # Une saisie en double n'est pas deux informations.
    with pytest.raises(psycopg.errors.ExclusionViolation):
        sql("INSERT INTO fermeture (id_lieu, periode) VALUES (%s, %s)",
            piscine, "[2026-08-01,2026-08-15)")


def test_la_pause_estivale_du_suaps_est_declaree(base):
    # Annoncée sur sport.univ-lorraine.fr : reprise le 7 septembre 2026.
    ferme = un("""
        SELECT count(*) FROM fermeture f JOIN lieu_sport l USING (id_lieu)
         WHERE l.code = 'PISCINE_SUAPS' AND f.periode @> DATE '2026-08-23'
    """)
    assert ferme == 1

    # La borne haute d'un DATERANGE est exclue : le 7 est bien ouvert.
    assert un("""
        SELECT count(*) FROM fermeture f JOIN lieu_sport l USING (id_lieu)
         WHERE l.code = 'PISCINE_SUAPS' AND f.periode @> DATE '2026-09-07'
    """) == 0


def test_un_lieu_sans_horaires_declares_est_toujours_ouvert(base):
    dimanche = prochain(7)
    plages = sql("SELECT plages_ouvertes((SELECT id_lieu FROM lieu_sport "
                 "WHERE code='SALLE'), %s) AS p", dimanche)

    # La salle n'a aucune ligne d'ouverture : c'est ainsi qu'on dit « toujours »
    # sans écrire sept lignes identiques.
    assert len(plages) == 1


# ---------------------------------------------------------------------------
# Trajet
# ---------------------------------------------------------------------------

def test_un_jour_de_cours_la_piscine_est_a_cinq_minutes(client, thomas):
    lundi = prochain_ouvert(1)
    cours(client, thomas, lundi, time(8), time(11))

    minutes = un("SELECT trajet_minutes(%s, %s, "
                 "(SELECT id_lieu FROM lieu_sport WHERE code='PISCINE_SUAPS'))",
                 identifiant(client), lundi)
    assert minutes == 5


def test_un_jour_sans_cours_elle_est_a_vingt_minutes(client, thomas):
    minutes = un("SELECT trajet_minutes(%s, %s, "
                 "(SELECT id_lieu FROM lieu_sport WHERE code='PISCINE_SUAPS'))",
                 identifiant(client), prochain(7))
    assert minutes == 20


# ---------------------------------------------------------------------------
# Repos avant la prochaine obligation
# ---------------------------------------------------------------------------

def test_une_seance_de_l_apres_midi_echappe_a_la_regle(client, thomas):
    jour = prochain(2)
    cours(client, thomas, jour, time(18), time(20))

    # La règle vise la nuit, pas l'après-midi : une séance à 15h avant un cours
    # à 18h ne pose aucun problème.
    assert un("SELECT repos_suffisant(%s, (SELECT id_lieu FROM lieu_sport "
              "WHERE code='SALLE'), %s)",
              identifiant(client),
              datetime.combine(jour, time(15), PARIS)) is True


def test_une_seance_tardive_avant_un_cours_du_matin_est_refusee(client, thomas):
    jour = prochain(2)
    cours(client, thomas, jour + timedelta(days=1), time(8), time(11))

    # Finir à 22h30 puis un cours à 8h : neuf heures et demie, il en faut dix.
    assert un("SELECT repos_suffisant(%s, (SELECT id_lieu FROM lieu_sport "
              "WHERE code='SALLE'), %s)",
              identifiant(client),
              datetime.combine(jour, time(22, 30), PARIS)) is False


def test_sans_rien_derriere_une_seance_tardive_passe(client, thomas):
    assert un("SELECT repos_suffisant(%s, (SELECT id_lieu FROM lieu_sport "
              "WHERE code='SALLE'), %s)",
              identifiant(client),
              datetime.combine(prochain(6), time(23), PARIS)) is True


def test_la_piscine_n_a_pas_de_regle_de_repos(client, thomas):
    assert un("SELECT repos_suffisant(%s, (SELECT id_lieu FROM lieu_sport "
              "WHERE code='PISCINE_SUAPS'), %s)",
              identifiant(client),
              datetime.combine(prochain(6), time(19), PARIS)) is True




# ---------------------------------------------------------------------------
# Les outils des scénarios
#
# Ils se jouent sur la semaine prochaine : elle est entière quel que soit le
# jour où la suite tourne.
# ---------------------------------------------------------------------------

def semaine(n: int = 1) -> date:
    """Le lundi de la semaine en cours décalée de n semaines."""
    aujourd_hui = datetime.now(PARIS).date()
    return aujourd_hui - timedelta(days=aujourd_hui.weekday()) + timedelta(weeks=n)


def lieu(code: str) -> int:
    return un("SELECT id_lieu FROM lieu_sport WHERE code = %s", code)


def a(jour: date, heure: int, minute: int = 0) -> datetime:
    return datetime.combine(jour, time(heure, minute), PARIS)


def _qui(pseudo: str = "thomas") -> int:
    return un("SELECT id_utilisateur FROM utilisateur WHERE pseudo = %s", pseudo)


def choisies(lundi: date, pseudo: str = "thomas") -> list[dict]:
    return sql("""
        SELECT o.id_occurrence, o.debut_seance, o.creneau, o.id_lieu, o.statut,
               o.epinglee, jour_de(o.debut_seance) AS jour
          FROM occurrence o JOIN tache t ON t.id_tache = o.id_tache
         WHERE t.code = 'SPORT'
           AND o.id_utilisateur = %s
           AND o.statut IN ('planifiee', 'notifiee', 'faite')
           AND jour_de(o.debut_seance) BETWEEN %s AND %s + 6
         ORDER BY o.debut_seance
    """, _qui(pseudo), lundi, lundi)


def placer(client, thomas) -> None:
    reponse = client.post("/planning/placer", headers=thomas)
    assert reponse.status_code == 200, reponse.text


# ---------------------------------------------------------------------------
# Ce que coûte une séance                                     (SPT-10, SPT-34)
# ---------------------------------------------------------------------------

def test_le_bloc_reserve_inclut_trajet_et_marges(client, thomas):
    jour = semaine(1)
    cours(client, thomas, jour, time(8), time(11))

    bloc = sql("SELECT lower(b) AS debut, upper(b) AS fin FROM "
               "bloc_de_seance(%s, %s, %s) b",
               identifiant(client), lieu("PISCINE_SUAPS"), a(jour, 12, 30))[0]

    # Trois quarts d'heure de nage, cinq minutes de marche depuis l'amphi,
    # une demi-heure de battement de chaque côté. Oublier le trajet ferait
    # tenir la séance dans un creux d'une heure, et manquer le cours suivant.
    assert bloc["fin"] - bloc["debut"] == timedelta(minutes=45 + 2 * 5 + 2 * 30)
    assert bloc["debut"].astimezone(PARIS).time() == time(11, 55)


def test_une_seance_porte_sa_propre_duree(client, thomas):
    jour = semaine(1)
    cours(client, thomas, jour, time(8), time(11))

    bloc = sql("SELECT lower(b) AS debut, upper(b) AS fin FROM "
               "bloc_de_seance(%s, %s, %s, 90) b",
               identifiant(client), lieu("PISCINE_SUAPS"), a(jour, 12, 30))[0]
    assert bloc["fin"] - bloc["debut"] == timedelta(minutes=90 + 2 * 5 + 2 * 30)


def test_sans_lieu_le_bloc_est_la_seance_seule(base):
    bloc = sql("SELECT lower(b) AS debut, upper(b) AS fin FROM "
               "bloc_de_seance(1, NULL, %s, 40) b", a(semaine(1), 18))[0]
    assert bloc["fin"] - bloc["debut"] == timedelta(minutes=40)
    assert un("SELECT bloc_de_seance(1, NULL, %s) IS NULL", a(semaine(1), 18)) is True


# ---------------------------------------------------------------------------
# Plus rien n'est réservé                                      (lot 2, SPT-33)
# ---------------------------------------------------------------------------

def test_le_placement_ne_reserve_plus_de_sport(client, thomas):
    placer(client, thomas)

    assert un("SELECT count(*) FROM occurrence WHERE origine = 'quota'") == 0
    assert choisies(semaine(1)) == []


def test_l_ancien_sport_a_quitte_la_base(base):
    retirees = ("organiser_sport", "organiser_sport_semaine", "propositions_sport",
                "habitudes_sport", "regler_minimum_sport", "minimum_sport",
                "alerte_sport_du_lundi", "seances_a_determiner_passees",
                "heures_seance_sport", "meilleure_heure_sport", "heures_candidates",
                "sportifs", "obstacle_seance_coach", "bloc_seance_duree", "duree_seance",
                # Le moteur d'avant la migration 033.
                "generer_seances_sport", "chercher_creneau_sport", "creneaux_sport_du_jour",
                "creneaux_sport_semaine", "creneaux_sport_horizon", "semaines_ouvertes",
                "seances_sport_restantes", "seances_sport_a_caser", "retenir_seance_sport",
                "caler_seance_sport", "fin_des_obligations")
    assert un("SELECT count(*) FROM pg_proc WHERE proname = ANY(%s)", list(retirees)) == 0
    # Une seule version de chacune des deux fonctions fusionnées.
    assert un("SELECT count(*) FROM pg_proc WHERE proname = 'obstacle_seance'") == 1
    assert un("SELECT count(*) FROM pg_proc WHERE proname = 'bloc_de_seance'") == 1
    # Les données ne sont pas perdues, seulement rangées.
    assert un("SELECT to_regclass('public.choix_sport') IS NULL") is True
    assert un("SELECT to_regclass('archive.choix_sport') IS NOT NULL") is True
    assert un("SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public'"
              " AND table_name = 'utilisateur' AND column_name = 'minimum_sport'") == 0


def test_la_migration_retire_les_reservations_ouvertes(client, thomas):
    from tests.conftest import RACINE

    moi = identifiant(client)
    jour = semaine(1) + timedelta(days=2)
    reservation = un("""
        INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, creneau, statut,
                                origine, id_lieu, debut_seance, motif)
        SELECT t.id_tache, %s, tstzrange(%s, %s), tstzrange(%s, %s), 'planifiee',
               'quota', %s, %s, 'À déterminer'
          FROM tache t WHERE t.code = 'SPORT'
        RETURNING id_occurrence
    """, moi, a(jour, 0), a(jour + timedelta(days=1), 0), a(jour, 17), a(jour, 19),
        lieu("SALLE"), a(jour, 17, 50))
    seance = sport.choisir(moi, lieu("COURSE"), a(jour + timedelta(days=1), 18))

    sql((RACINE / "sql" / "065_retrait_reservations_sport.sql").read_text())

    assert un("SELECT count(*) FROM occurrence WHERE id_occurrence = %s", reservation) == 0
    assert un("SELECT statut FROM occurrence WHERE id_occurrence = %s", seance) == "planifiee"


# ---------------------------------------------------------------------------
# Poser une séance à la main                           (SPT-19, SPT-21, SPT-37)
# ---------------------------------------------------------------------------

def test_une_seance_choisie_est_epinglee_a_l_heure_dite(client, thomas):
    lundi = semaine(1)
    moi = identifiant(client)
    voulu = a(lundi + timedelta(days=1), 18, 15)
    sport.choisir(moi, lieu("SALLE"), voulu)
    placer(client, thomas)

    seance = choisies(lundi)[0]
    assert seance["epinglee"]
    # L'heure donnée est celle de la séance. Le trajet et la marge s'ajoutent
    # avant : vingt minutes de trajet, une demi-heure de battement.
    assert seance["debut_seance"] == voulu
    assert seance["creneau"].lower == voulu - timedelta(minutes=50)


def test_deux_seances_par_jour_au_plus(client, thomas):
    lundi = semaine(1)
    moi = identifiant(client)
    sport.choisir(moi, lieu("COURSE"), a(lundi, 7))
    sport.choisir(moi, lieu("SALLE"), a(lundi, 18))

    with pytest.raises(psycopg.Error, match="Deux séances"):
        sport.choisir(moi, lieu("PISCINE_SUAPS"), a(lundi, 12, 30))


def test_on_ne_se_met_pas_en_plein_cours(client, thomas):
    lundi = semaine(1)
    cours(client, thomas, lundi, time(14), time(17))

    with pytest.raises(psycopg.Error, match="Cours"):
        sport.choisir(identifiant(client), lieu("SALLE"), a(lundi, 15))


def test_on_peut_choisir_ce_que_hal_ne_proposerait_pas(client, thomas):
    # SPT-17 : la piscine est fermée à 15h, mais on sait parfois mieux que HAL.
    mardi = semaine(1) + timedelta(days=1)
    moi = identifiant(client)
    assert un("SELECT obstacle_seance(%s, %s, %s)", moi, lieu("PISCINE_SUAPS"),
              a(mardi, 15)) == "Le lieu est fermé à cette heure-là"

    sport.choisir(moi, lieu("PISCINE_SUAPS"), a(mardi, 15))
    assert len(choisies(semaine(1))) == 1


def test_deplacer_sa_seance(client, thomas):
    lundi = semaine(1)
    moi = identifiant(client)
    seance = sport.choisir(moi, lieu("SALLE"), a(lundi + timedelta(days=1), 18))

    assert sport.choisir(moi, lieu("COURSE"), a(lundi + timedelta(days=2), 7), seance) == seance
    deplacee = choisies(lundi)[0]
    assert deplacee["id_lieu"] == lieu("COURSE")
    assert deplacee["debut_seance"] == a(lundi + timedelta(days=2), 7)


# ---------------------------------------------------------------------------
# Faite, pas faite                                              (SPT-25, SPT-36)
# ---------------------------------------------------------------------------

def test_pas_faite_est_close_sans_rien_recompleter(client, thomas):
    lundi = semaine(1)
    moi = identifiant(client)
    seance = sport.choisir(moi, lieu("COURSE"), a(lundi + timedelta(days=1), 18))

    sql("SELECT seance_sport_pas_faite(%s, %s)", moi, seance)

    assert un("SELECT statut FROM occurrence WHERE id_occurrence = %s", seance) == "abandonnee"
    # SPT-36 : la semaine ne se recomplète plus d'elle-même.
    assert un("SELECT count(*) FROM occurrence o JOIN tache t USING (id_tache)"
              " WHERE t.code = 'SPORT' AND o.statut IN ('planifiee', 'notifiee')") == 0


def test_refuser_une_seance_ne_la_reassigne_pas(client, thomas):
    lundi = semaine(1)
    moi = identifiant(client)
    seance = sport.choisir(moi, lieu("COURSE"), a(lundi + timedelta(days=1), 18))

    reponse = conv.executer_action("refuser", seance, moi)

    assert "pas faite" in reponse.lower()
    assert un("SELECT statut FROM occurrence WHERE id_occurrence = %s", seance) == "abandonnee"
    # Aucune remplaçante sans assigné : ce n'est pas du ménage.
    assert un("SELECT count(*) FROM occurrence WHERE id_occurrence_source = %s", seance) == 0


def test_supprimer_une_seance_ne_laisse_rien(client, thomas):
    moi = identifiant(client)
    seance = sport.choisir(moi, lieu("SALLE"), a(semaine(1) + timedelta(days=1), 18))

    sql("SELECT supprimer_seance_sport(%s, %s)", moi, seance)

    assert un("SELECT count(*) FROM occurrence WHERE id_occurrence = %s", seance) == 0
    assert choisies(semaine(1)) == []


def test_la_relance_du_soir_nomme_le_sport(client, thomas):
    moi = identifiant(client)
    seance = sport.choisir(moi, lieu("PISCINE_SUAPS"),
                           a(semaine(1) + timedelta(days=1), 12, 30))
    sql("UPDATE occurrence SET statut = 'notifiee', "
        "creneau = tstzrange(debut_jour(jour_de(now())) + INTERVAL '1 hour', "
        "debut_jour(jour_de(now())) + INTERVAL '2 hours'), "
        "fenetre = tstzrange(debut_jour(jour_de(now())), debut_jour(jour_de(now()) + 1)) "
        "WHERE id_occurrence = %s", seance)

    sql("SELECT relance_du_soir()")

    assert un("SELECT contenu FROM notification WHERE id_occurrence = %s",
              seance) == "Piscine du SUAPS : c'est fait ?"


def test_une_seance_ne_se_reporte_pas_au_lendemain(client, thomas):
    moi = identifiant(client)
    seance = sport.choisir(moi, lieu("SALLE"), a(semaine(1) + timedelta(days=1), 18))
    sql("UPDATE occurrence SET creneau = tstzrange(debut_jour(jour_de(now()) - 1) "
        "+ INTERVAL '3 hours', debut_jour(jour_de(now()) - 1) + INTERVAL '4 hours'), "
        "fenetre = tstzrange(debut_jour(jour_de(now()) - 1), debut_jour(jour_de(now()))), "
        "statut = 'notifiee' WHERE id_occurrence = %s", seance)

    client.post("/notifications/report", headers=thomas)

    # Elle attend sa réponse : faite, ou pas faite. Pas de glissement au
    # lendemain comme une tâche.
    detail = sql("SELECT statut, creneau FROM occurrence WHERE id_occurrence = %s", seance)[0]
    assert detail["statut"] == "notifiee"
    assert detail["creneau"] is not None


# ---------------------------------------------------------------------------

# L'ancre après les cours, et ce que le texte sait lire              (SPT-12, SPT-17)
# ---------------------------------------------------------------------------

def _travail(client, thomas, jour: date, debut: time, fin: time) -> None:
    """Un service qui déborde sur le lendemain quand il finit à minuit."""
    d = datetime.combine(jour, debut, PARIS)
    f = (datetime.combine(jour, time(0), PARIS) + timedelta(days=1)
         if fin == time(0) else datetime.combine(jour, fin, PARIS))
    with psycopg.connect(_url(), autocommit=True) as conn:
        conn.execute(
            "INSERT INTO occupation (id_utilisateur, id_source, type, libelle, periode) "
            "VALUES (%s, (SELECT id_source FROM source WHERE code='MANUELLE'), "
            "        'travail', %s, tstzrange(%s, %s, '[)'))",
            (identifiant(client), "Service", d, f))


def test_l_ancre_ignore_le_service_du_soir(client, thomas):
    jour = semaine(1) + timedelta(days=1)
    cours(client, thomas, jour, time(10), time(11, 30))
    cours(client, thomas, jour, time(15, 30), time(17, 30))
    _travail(client, thomas, jour, time(19, 15), time(0))

    ancre = un("SELECT fin_des_cours(%s, %s)", identifiant(client), jour)
    # La fin des cours, pas la fin du service.
    assert ancre.astimezone(PARIS).time() == time(17, 30)


def test_un_service_du_soir_n_empeche_pas_de_courir(client, thomas):
    jour = semaine(1) + timedelta(days=1)
    cours(client, thomas, jour, time(10), time(11, 30))
    cours(client, thomas, jour, time(15, 30), time(17, 30))
    _travail(client, thomas, jour, time(19, 15), time(0))

    # Juste après les cours, la course tient avant le service.
    assert un("SELECT obstacle_seance(%s, %s, %s)", identifiant(client), lieu("COURSE"),
              a(jour, 17, 50)) is None



# Les séances à deux                                           (SPT-30 à SPT-32)
# ---------------------------------------------------------------------------

def _invitation(pseudo: str = "lorette") -> dict:
    return sql("""
        SELECT inv.id_invitation, inv.statut, inv.id_occurrence
          FROM invitation_sport inv
          JOIN utilisateur u ON u.id_utilisateur = inv.id_invite
         WHERE u.pseudo = %s
         ORDER BY inv.id_invitation DESC LIMIT 1
    """, pseudo)[0]



def _seance_invitee(debut: datetime) -> int:
    """Thomas pose sa séance et la propose à Lorette, comme depuis l'appli."""
    seance = sport.choisir(_qui("thomas"), lieu("SALLE"), debut)
    assert sport.inviter(seance) == 1
    return seance


def test_un_creneau_ou_l_autre_travaille_n_est_pas_a_deux(client, thomas, lorette):
    moi, elle = _qui("thomas"), _qui("lorette")
    mardi = semaine(1) + timedelta(days=1)
    debut = a(mardi, 18)
    # Lorette est en cours au même moment.
    sql("INSERT INTO occupation (id_utilisateur, id_source, type, libelle, periode) "
        "VALUES (%s, (SELECT id_source FROM source WHERE code='MANUELLE'), 'cours', "
        "        'Anatomie', tstzrange(%s, %s::TIMESTAMPTZ + INTERVAL '4 hours', '[)'))",
        elle, a(mardi, 16), a(mardi, 16))

    assert sport.possible_a_deux(moi, lieu("SALLE"), debut) is False
    assert sport.possible_a_deux(moi, lieu("SALLE"), a(mardi + timedelta(days=1), 18))



def test_inviter_previent_l_autre(client, thomas):
    debut = a(semaine(1) + timedelta(days=1), 18)
    _seance_invitee(debut)

    invitation = _invitation()
    assert invitation["statut"] == "attente"
    # La question part par notification, avec de quoi répondre.
    notification = sql("SELECT contenu, id_invitation FROM notification "
                       " WHERE id_invitation IS NOT NULL")[0]
    assert "Tu viens ?" in notification["contenu"]
    assert notification["id_invitation"] == invitation["id_invitation"]
    assert len(choisies(semaine(1))) == 1
    assert choisies(semaine(1), "lorette") == []


def test_inviter_depuis_l_appli(client, thomas):
    seance = sport.choisir(_qui("thomas"), lieu("SALLE"), a(semaine(1) + timedelta(days=1), 18))

    reponse = client.post(f"/seances/{seance}/inviter", headers=thomas)
    assert reponse.status_code == 200, reponse.text
    assert reponse.json() == {"invites": 1}
    assert client.post("/seances/999999/inviter", headers=thomas).status_code == 404


def test_accepter_cree_sa_propre_seance(client, thomas):
    elle = _qui("lorette")
    debut = a(semaine(1) + timedelta(days=1), 18)
    _seance_invitee(debut)
    invitation = _invitation()

    assert sport.repondre_a_l_invitation(elle, invitation["id_invitation"], True)

    siennes = choisies(semaine(1), "lorette")
    assert len(siennes) == 1
    assert siennes[0]["debut_seance"] == debut
    assert un("SELECT statut FROM invitation_sport WHERE id_invitation = %s",
              invitation["id_invitation"]) == "acceptee"
    # Chacun a sa séance : ce sont deux occurrences, pas une partagée.
    assert siennes[0]["id_occurrence"] != choisies(semaine(1))[0]["id_occurrence"]


def test_refuser_ne_defait_rien(client, thomas):
    elle = _qui("lorette")
    _seance_invitee(a(semaine(1) + timedelta(days=1), 18))
    invitation = _invitation()

    sport.repondre_a_l_invitation(elle, invitation["id_invitation"], False)

    assert choisies(semaine(1), "lorette") == []
    # SPT-32 : la séance de Thomas tient, on peut y aller seul.
    assert len(choisies(semaine(1))) == 1
    assert un("SELECT statut FROM invitation_sport WHERE id_invitation = %s",
              invitation["id_invitation"]) == "refusee"


def test_on_ne_repond_qu_une_fois(client, thomas):
    elle = _qui("lorette")
    _seance_invitee(a(semaine(1) + timedelta(days=1), 18))
    invitation = _invitation()["id_invitation"]
    sport.repondre_a_l_invitation(elle, invitation, True)

    with pytest.raises(psycopg.Error):
        sport.repondre_a_l_invitation(elle, invitation, False)
    assert len(choisies(semaine(1), "lorette")) == 1


def test_la_seance_dit_qui_vient(client, thomas):
    elle = _qui("lorette")
    ma_seance = _seance_invitee(a(semaine(1) + timedelta(days=1), 18))
    sport.repondre_a_l_invitation(elle, _invitation()["id_invitation"], True)

    assert [c["nom"] for c in sport.compagnons(ma_seance)] == ["Lorette"]


def test_supprimer_sa_seance_retire_l_invitation(client, thomas):
    ma_seance = _seance_invitee(a(semaine(1) + timedelta(days=1), 18))

    sql("SELECT supprimer_seance_sport(%s, %s)", _qui("thomas"), ma_seance)

    assert un("SELECT count(*) FROM invitation_sport") == 0


def test_une_invitation_acceptee_survit_a_l_annulation(client, thomas):
    elle = _qui("lorette")
    ma_seance = _seance_invitee(a(semaine(1) + timedelta(days=1), 18))
    sport.repondre_a_l_invitation(elle, _invitation()["id_invitation"], True)

    sql("SELECT supprimer_seance_sport(%s, %s)", _qui("thomas"), ma_seance)

    # SPT-32 : elle avait dit qu'elle venait, sa séance lui appartient.
    assert len(choisies(semaine(1), "lorette")) == 1
