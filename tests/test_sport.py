"""Séances de sport : le lieu a des heures, le trajet compte, la nuit aussi.

Une séance ressemble à une tâche ménagère — elle revient, elle dure, elle se
place dans un creux. Trois choses l'en distinguent, et ce sont elles qu'on
vérifie ici.

La piscine n'ouvre au public que deux heures à midi : proposer 15h reviendrait
à proposer une porte close. Le trajet n'est pas du sport mais occupe l'agenda,
et l'oublier ferait tenir une heure de piscine dans un creux d'une heure. Enfin
la salle est ouverte la nuit, ce qui n'est une bonne nouvelle que si l'on peut
dormir ensuite.
"""

from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

import psycopg

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

    # R99 : les heures d'ouverture disent une semaine type. Elles ne disent
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


def test_pendant_la_fermeture_la_salle_prend_le_relais(client, thomas):
    # Nous sommes en pause estivale : aucune séance ne doit être à la piscine.
    for rang in range(1, 6):
        cours(client, thomas, prochain(rang), time(8), time(11))
    client.post("/planning/placer", headers=thomas)

    posees = seances(client, thomas)
    assert posees
    en_ete = [s for s in posees
              if s["debut"].astimezone(PARIS).date() < date(2026, 9, 7)]
    assert all(s["lieu"] == "SALLE" for s in en_ete), en_ete


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


def test_le_creneau_reserve_inclut_l_aller_et_le_retour(client, thomas):
    for rang in range(1, 6):
        cours(client, thomas, prochain_ouvert(rang), time(8), time(11))
    client.post("/planning/placer", headers=thomas)

    posees = [s for s in seances(client, thomas) if s["lieu"] == "PISCINE_SUAPS"]
    assert posees

    # Une heure de nage, cinq minutes de marche de chaque côté. Ignorer le
    # trajet ferait tenir la séance dans un creux d'une heure, et manquer le
    # cours suivant.
    duree = posees[0]["fin"] - posees[0]["debut"]
    assert duree == timedelta(minutes=70)
    assert posees[0]["debut"].astimezone(PARIS).time() == time(11, 55)


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
# Placement
# ---------------------------------------------------------------------------

def test_trois_seances_par_semaine(client, thomas):
    for rang in range(1, 6):
        cours(client, thomas, prochain(rang), time(8), time(11))
    client.post("/planning/placer", headers=thomas)

    lundi = prochain(1)
    cette_semaine = [s for s in seances(client, thomas)
                     if lundi <= s["debut"].astimezone(PARIS).date() < lundi + timedelta(days=7)]

    # R94 : « trois fois par semaine » se compte semaine par semaine, et ne se
    # traduit pas en « tous les 2,33 jours ».
    assert len(cette_semaine) == 3


def test_jamais_deux_seances_le_meme_jour(client, thomas):
    for rang in range(1, 6):
        cours(client, thomas, prochain(rang), time(8), time(11))
    client.post("/planning/placer", headers=thomas)

    jours = [s["debut"].astimezone(PARIS).date() for s in seances(client, thomas)]
    # Trois séances entassées le même après-midi ne font pas trois séances.
    assert len(jours) == len(set(jours))


def test_la_piscine_passe_avant_la_salle(client, thomas):
    for rang in range(1, 6):
        cours(client, thomas, prochain_ouvert(rang), time(8), time(11))
    client.post("/planning/placer", headers=thomas)

    lundi = prochain_ouvert(1)
    semaine = [s for s in seances(client, thomas)
               if lundi <= s["debut"].astimezone(PARIS).date() < lundi + timedelta(days=7)]
    assert all(s["lieu"] == "PISCINE_SUAPS" for s in semaine), semaine


def test_midi_occupe_renvoie_a_la_salle(client, thomas):
    # Cours de 8h à 15h toute la semaine : le créneau de midi est mangé, et
    # celui de 16h aussi le jour où le cours déborde.
    for rang in range(1, 6):
        cours(client, thomas, prochain(rang), time(8), time(18))
    client.post("/planning/placer", headers=thomas)

    posees = seances(client, thomas)
    assert posees
    assert any(s["lieu"] == "SALLE" for s in posees)


def test_a_la_salle_le_creneau_est_le_plus_tard_possible(client, thomas):
    jour = prochain(6)  # samedi : la piscine est fermée
    client.post("/planning/placer", headers=thomas)

    a_la_salle = [s for s in seances(client, thomas)
                  if s["lieu"] == "SALLE"
                  and s["debut"].astimezone(PARIS).date() == jour]
    if not a_la_salle:
        return  # le quota a pu être atteint ailleurs dans la semaine

    # R97 : prendre le plus tôt proposerait 9h du matin. La salle est le lieu
    # où l'on va le soir, une fois le reste fait.
    fin = a_la_salle[0]["fin"].astimezone(PARIS).time()
    assert fin >= time(20)


def test_une_seance_ne_tombe_pas_un_jour_d_absence(client, thomas):
    for rang in range(1, 6):
        cours(client, thomas, prochain(rang), time(8), time(11))

    debut = datetime.combine(prochain(1), time(0), PARIS)
    client.post("/absences", headers=thomas, json={
        "debut": debut.isoformat(),
        "fin": (debut + timedelta(days=3)).isoformat(),
        "lieu": "Lusse",
    })
    client.post("/planning/placer", headers=thomas)

    jours = {s["debut"].astimezone(PARIS).date() for s in seances(client, thomas)}
    assert prochain(1) not in jours
    assert prochain(2) not in jours


# ---------------------------------------------------------------------------
# Ce que le sport ne doit pas faire
# ---------------------------------------------------------------------------

def test_le_sport_ne_compte_pas_dans_la_balance_du_menage(client, thomas):
    for rang in range(1, 6):
        cours(client, thomas, prochain(rang), time(8), time(11))
    client.post("/planning/placer", headers=thomas)

    moi = identifiant(client)
    menageres = sql("""
        SELECT o.id_utilisateur, count(*) AS n
          FROM occurrence o JOIN tache t ON t.id_tache = o.id_tache
         WHERE t.categorie <> 'sport' AND o.creneau IS NOT NULL
         GROUP BY 1
    """)

    # R98 : compter le sport reviendrait à payer ses séances de piscine en
    # heures de ménage — et à donner l'appartement entier à l'autre.
    a_moi = next((ligne["n"] for ligne in menageres
                  if ligne["id_utilisateur"] == moi), 0)
    assert a_moi > 0, menageres


def test_le_sport_reste_a_son_proprietaire(client, thomas, lorette):
    for rang in range(1, 6):
        cours(client, thomas, prochain(rang), time(8), time(11))
    client.post("/planning/placer", headers=thomas)

    proprietaires = {s["id_utilisateur"] for s in seances(client, thomas)}
    # Une séance de sport ne se répartit pas entre colocataires.
    assert len(proprietaires) == 1


def test_la_seance_apparait_au_calendrier_avec_son_lieu(client, thomas):
    from icalendar import Calendar

    from tests.conftest import JETON_THOMAS

    for rang in range(1, 6):
        cours(client, thomas, prochain(rang), time(8), time(11))
    client.post("/planning/placer", headers=thomas)

    flux = client.get("/planning.ics", params={"cle": JETON_THOMAS})
    evenements = [e for e in Calendar.from_ical(flux.content).walk("VEVENT")
                  if str(e.get("SUMMARY", "")).startswith("Sport :")]

    assert evenements
    # Le titre porte le lieu, pas « Séance de sport » : c'est lui qui dit s'il
    # faut prendre son maillot ou ses baskets.
    assert any("Piscine" in str(e.get("LOCATION", "")) for e in evenements)
    assert any("Piscine" in str(e["SUMMARY"]) for e in evenements)
    # Une séance a une heure : ce n'est pas un rappel « dans la journée ».
    assert all(e["DTSTART"].params.get("VALUE") != "DATE" for e in evenements)
