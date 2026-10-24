"""Le journal des événements                                      (JRN-1 à JRN-9)

Presque toutes les questions posées à cette application avaient la même forme :
« pourquoi ça a fait ça ? ». Y répondre demandait de relire le code et de
deviner. Le journal note ce qui change, qui l'a déclenché, et dans quelle
action : la cause se lit à côté de l'effet.

Ces tests tiennent trois promesses. Le journal ne rate rien de ce qui compte.
Il ne note pas ce qui ne compte pas, sinon personne ne le lira. Et il ne casse
jamais ce qu'il observe.
"""

import asyncio
from datetime import datetime, timedelta
from types import SimpleNamespace
from zoneinfo import ZoneInfo

import psycopg
import pytest

from api import absences, administration, appairage, billets, bot_des_membres, journal, operation
from api.ordonnanceur import placer, report_de_minuit
from tests.conftest import CLE_THOMAS, _url

PARIS = ZoneInfo("Europe/Paris")


def sql(requete: str, *parametres):
    with psycopg.connect(_url(), row_factory=psycopg.rows.dict_row,
                         autocommit=True) as conn:
        curseur = conn.execute(requete, parametres or None)
        return curseur.fetchall() if curseur.description else []


def un(requete: str, *parametres):
    lignes = sql(requete, *parametres)
    return next(iter(lignes[0].values())) if lignes else None


def _id(pseudo: str) -> int:
    return un("SELECT id_utilisateur FROM utilisateur WHERE pseudo = %s", pseudo)


def minuit(dans_jours: int) -> datetime:
    return (datetime.now(PARIS) + timedelta(days=dans_jours)).replace(
        hour=0, minute=0, second=0, microsecond=0)


def evenements(objet: str | None = None) -> list[dict]:
    return sql("SELECT * FROM evenement WHERE %s::TEXT IS NULL OR objet = %s "
               "ORDER BY id_evenement", objet, objet)


@pytest.fixture
def place(client, thomas):
    """Un planning posé, et un journal qui repart de zéro."""
    client.post("/planning/placer", headers=thomas)
    sql("DELETE FROM evenement")


# ---------------------------------------------------------------------------
# Ce qui est noté, et au nom de qui                               JRN-1, JRN-4
# ---------------------------------------------------------------------------

def test_un_appel_de_l_api_est_note_au_nom_de_celui_qui_l_a_fait(client, thomas):
    client.post("/absences", headers=thomas, json={
        "debut": minuit(3).isoformat(), "fin": minuit(6).isoformat(), "lieu": "Lusse"})

    (note,) = evenements("absence")
    assert note["acteur"] == "thomas"
    assert note["origine"] == "api : POST /absences"
    assert note["libelle"] == "Lusse"
    # Créée : pas d'état avant, et l'état après dit à qui et quand.
    assert note["avant"] is None
    assert note["apres"]["id_utilisateur"] == _id("thomas")


def test_la_cause_et_l_effet_portent_le_meme_numero(client, thomas, place):
    """Ce pour quoi le journal existe.

    Une absence déclarée déplace des tâches. Les deux doivent se lire ensemble :
    c'est ce qui répond à « pourquoi l'aspirateur a changé de jour ».
    """
    with operation.ouvrir("bot : /absent", acteur="thomas"):
        absences.declarer_absence(_id("thomas"), minuit(1), minuit(5), "Lusse")
        placer()

    operations = {e["operation"] for e in evenements()}
    assert len(operations) == 1, "tout vient de la même action"
    objets = {e["objet"] for e in evenements()}
    assert "absence" in objets
    assert "occurrence" in objets, "l'absence a bien déplacé des tâches"
    assert {e["acteur"] for e in evenements()} == {"thomas"}


def test_sans_contexte_l_evenement_est_note_quand_meme(base):
    # Une requête tapée à la main dans psql, ou un chemin qu'on a oublié de
    # brancher : le journal note, et dit qu'il ne sait pas qui.
    sql("INSERT INTO absence (id_utilisateur, periode, lieu, origine) "
        "VALUES (%s, tstzrange(%s, %s), 'Metz', 'manuelle')",
        _id("lorette"), minuit(2), minuit(3))

    (note,) = evenements("absence")
    assert note["acteur"] == "direct"
    assert note["operation"].startswith("tx")


# ---------------------------------------------------------------------------
# Ce qui n'est pas noté                                           JRN-2, JRN-3
# ---------------------------------------------------------------------------

def test_un_placement_qui_ne_change_rien_ne_note_rien(client, thomas, place):
    """Le placement défait tout ce qui n'est pas gelé avant de le reposer.

    Noter chaque geste donnerait des dizaines de lignes pour dire que rien n'a
    bougé, toutes les heures. Personne ne lirait un journal pareil.
    """
    # Un passage de plus, pour ce qui vient d'entrer dans l'horizon : une tâche
    # dont la fenêtre s'ouvre pile au bord n'est placée qu'à la seconde suivante.
    placer()
    sql("DELETE FROM evenement")

    placer()

    deja_placees = [e for e in evenements("occurrence")
                    if e["avant"] and e["avant"].get("creneau")]
    assert deja_placees == [], "une tâche déjà placée n'a pas bougé : rien à dire"
    assert len(evenements()) <= 2


def test_une_tache_placee_se_lit_avec_son_jour_et_sa_personne(client, thomas):
    client.post("/planning/placer", headers=thomas)

    texte = journal.raconter()

    assert "nouvelle, " in texte
    assert " pour Thomas" in texte or " pour Lorette" in texte
    # Jamais « personne » : une tâche placée a quelqu'un.
    assert "personne" not in texte


def test_une_ligne_par_objet_quel_que_soit_le_nombre_de_retouches(base):
    moi = _id("thomas")
    with operation.ouvrir("essai", acteur="thomas"):
        absence = absences.declarer_absence(moi, minuit(2), minuit(4), "Lusse")
        identifiant = absence["id_absence"]
        sql_dans_l_action("UPDATE absence SET lieu = 'Metz' WHERE id_absence = %s",
                          identifiant)
        sql_dans_l_action("UPDATE absence SET lieu = 'Nancy' WHERE id_absence = %s",
                          identifiant)

    (note,) = evenements("absence")
    # L'état d'avant l'action, et le dernier : pas les étapes.
    assert note["avant"] is None
    assert note["apres"]["lieu"] == "Nancy"


def sql_dans_l_action(requete: str, *parametres) -> None:
    """Une écriture qui passe par l'API, donc qui porte l'action en cours."""
    from api.base import connexion
    with connexion() as conn:
        conn.execute(requete, parametres)


def test_revenir_au_point_de_depart_efface_l_evenement(base):
    moi = _id("thomas")
    absence = absences.declarer_absence(moi, minuit(2), minuit(4), "Lusse")
    sql("DELETE FROM evenement")

    with operation.ouvrir("essai", acteur="thomas"):
        sql_dans_l_action("UPDATE absence SET lieu = 'Metz' WHERE id_absence = %s",
                          absence["id_absence"])
        assert len(evenements("absence")) == 1
        sql_dans_l_action("UPDATE absence SET lieu = 'Lusse' WHERE id_absence = %s",
                          absence["id_absence"])

    assert evenements("absence") == []


def test_une_retouche_hors_des_colonnes_suivies_ne_compte_pas(base):
    moi = _id("thomas")
    absence = absences.declarer_absence(moi, minuit(2), minuit(4), "Lusse")
    sql("DELETE FROM evenement")

    # Le commentaire n'est pas suivi : c'est ce qui permet à la collecte de
    # réécrire quatre-vingts cours identiques sans remplir le journal.
    sql("UPDATE absence SET commentaire = 'peu importe' WHERE id_absence = %s",
        absence["id_absence"])

    assert evenements() == []


def test_seul_le_train_retenu_est_un_evenement(base):
    moi = _id("thomas")
    # Chercher un train en propose une vingtaine : ce ne sont pas des faits.
    trajet = un("""
        INSERT INTO trajet (id_utilisateur, sens, periode, origine, destination)
        VALUES (%s, 'aller', tstzrange(%s, %s), 'Nancy', 'Saint-Dié')
        RETURNING id_trajet""", moi, minuit(3), minuit(3) + timedelta(hours=1))
    assert evenements("trajet") == []

    sql("UPDATE trajet SET statut = 'retenue' WHERE id_trajet = %s", trajet)

    (note,) = evenements("trajet")
    assert note["apres"]["statut"] == "retenue"


def test_l_adresse_d_une_source_n_entre_pas_au_journal(base):
    # L'URL d'un calendrier privé contient son jeton d'accès.
    sql("UPDATE source SET url = 'https://exemple.test/prive?jeton=SECRET', active = TRUE "
        " WHERE code = 'PERSO_THOMAS'")

    tout = str(sql("SELECT avant, apres, libelle, detail FROM evenement"))
    assert "SECRET" not in tout
    # Le changement, lui, est bien noté : la source est suivie de nouveau.
    assert len(evenements("source")) == 1


# ---------------------------------------------------------------------------
# Le journal ne casse rien                                               JRN-5
# ---------------------------------------------------------------------------

def test_un_journal_en_panne_n_empeche_pas_de_declarer_une_absence(base):
    sql("ALTER TABLE evenement ADD CONSTRAINT essai_panne "
        "CHECK (objet <> 'absence') NOT VALID")
    try:
        creee = absences.declarer_absence(_id("thomas"), minuit(2), minuit(4), "Lusse")
    finally:
        sql("ALTER TABLE evenement DROP CONSTRAINT essai_panne")

    # L'absence existe, le journal a seulement manqué une ligne.
    assert un("SELECT count(*) FROM absence WHERE id_absence = %s",
              creee["id_absence"]) == 1
    assert evenements("absence") == []


# ---------------------------------------------------------------------------
# Qui lit quoi                                                           JRN-6
# ---------------------------------------------------------------------------

def test_le_foyer_se_lit_a_deux_le_technique_reste_a_l_admin(client, thomas, lorette):
    client.post("/absences", headers=thomas, json={
        "debut": minuit(3).isoformat(), "fin": minuit(6).isoformat(), "lieu": "Lusse"})
    journal.noter("deploiement", "Déploiement de abc1234", technique=True)

    pour_elle = str(client.get("/journal", headers=lorette).json())
    pour_lui = str(client.get("/journal", headers=thomas).json())

    # Lorette voit l'absence de Thomas : c'est ce qui explique ses tâches.
    assert "Absence de Thomas" in pour_elle
    assert "Déploiement" not in pour_elle
    assert "Déploiement" in pour_lui


def test_le_journal_demande_une_cle(client):
    assert client.get("/journal").status_code == 401


# ---------------------------------------------------------------------------
# /pourquoi                                                              JRN-9
# ---------------------------------------------------------------------------

def test_pourquoi_raconte_l_action_avec_son_auteur(base):
    with operation.ouvrir("bot : /absent", acteur="thomas"):
        absences.declarer_absence(_id("thomas"), minuit(2), minuit(4), "Lusse")

    texte = journal.raconter()

    assert "Thomas" in texte
    assert "/absent" in texte
    assert "Absence de Thomas : Lusse, du " in texte


def test_pourquoi_avec_un_mot_montre_aussi_ce_qui_l_a_provoque(client, thomas, place):
    with operation.ouvrir("bot : /absent", acteur="thomas"):
        absences.declarer_absence(_id("thomas"), minuit(1), minuit(5), "Lusse")
        placer()
    deplacee = next(e for e in evenements("occurrence"))

    texte = journal.raconter(deplacee["libelle"])

    assert deplacee["libelle"] in texte
    # La réponse à « pourquoi » : l'absence, dans la même action.
    assert "Dans la même action" in texte
    assert "Absence de Thomas" in texte


def test_la_recherche_ignore_les_accents_et_la_casse(base):
    with operation.ouvrir("essai", acteur="lorette"):
        absences.declarer_absence(_id("lorette"), minuit(2), minuit(4), "Saint-Dié")

    assert "Saint-Dié" in journal.raconter("saint-die")
    assert "Saint-Dié" in journal.raconter("LORETTE")


def test_un_mot_inconnu_le_dit(base):
    assert "Rien dans le journal" in journal.raconter("licorne")


def test_un_journal_vide_le_dit(base):
    assert "vide" in journal.raconter()


def test_ce_qui_vient_des_donnees_est_echappe(base):
    # Le texte part en HTML : un lieu saisi avec un chevron casserait l'envoi.
    with operation.ouvrir("essai", acteur="thomas"):
        absences.declarer_absence(_id("thomas"), minuit(2), minuit(4), "Chez <Mamie>")

    texte = journal.raconter()

    assert "&lt;Mamie&gt;" in texte
    assert "<Mamie>" not in texte


def test_un_message_parti_normalement_n_encombre_pas(base):
    lui = _id("thomas")
    with operation.ouvrir("Bilan du matin", acteur="ordonnanceur"):
        sql_dans_l_action("INSERT INTO notification (id_utilisateur, type, contenu) "
                          "VALUES (%s, 'bilan', 'Bonjour, <b>trois</b> tâches')", lui)
    numero = un("SELECT max(id_notification) FROM notification")
    with operation.ouvrir("envoi des messages", acteur="bot"):
        administration.marquer_envoyee(numero, True)

    texte = journal.raconter()

    # La préparation du message se lit, avec son texte sans balises.
    assert "Message pour Thomas : « Bonjour, trois tâches »" in texte
    # L'envoi réussi est de la routine : il ne fait pas une action de plus.
    assert "envoi des messages" not in texte
    # Mais il est au journal, pour qui le cherche.
    assert "Message envoyé à Thomas" in journal.raconter("envoyé")


def test_un_envoi_rate_se_voit(base):
    sql("INSERT INTO notification (id_utilisateur, type, contenu) "
        "VALUES (%s, 'rappel', 'Sortir les poubelles')", _id("lorette"))
    sql("DELETE FROM evenement")
    with operation.ouvrir("envoi des messages", acteur="bot"):
        administration.marquer_envoyee(un("SELECT max(id_notification) FROM notification"), False)

    assert "Envoi raté pour Lorette : « Sortir les poubelles »" in journal.raconter()


def test_faire_la_tache_de_l_autre_se_lit_en_une_ligne(client, thomas, place):
    sienne = sql("""
        SELECT o.id_occurrence, t.libelle FROM occurrence o JOIN tache t USING (id_tache)
         WHERE o.id_utilisateur = %s AND o.statut = 'planifiee'
           AND t.categorie <> 'sport' AND NOT t.requiert_les_deux
         ORDER BY lower(o.creneau) LIMIT 1""", _id("lorette"))[0]

    with operation.ouvrir("bot : bouton Fait", acteur="thomas"):
        bot_des_membres.executer_action("valider", sienne["id_occurrence"], _id("thomas"))

    texte = journal.raconter()
    assert f"{sienne['libelle']} : faite par Thomas, c'était à Lorette" in texte
    assert "bouton Fait" in texte


# ---------------------------------------------------------------------------
# Les faits sans ligne de table                                          JRN-7
# ---------------------------------------------------------------------------

def test_une_releve_a_la_main_qui_ne_trouve_rien_laisse_une_trace(base):
    # « /billets » qui répond « rien de neuf » : c'est là qu'on demande pourquoi.
    with operation.ouvrir("bot : /billets", acteur="thomas"):
        billets.relever(_id("thomas"), messages=[])

    (note,) = evenements("releve")
    assert note["detail"] == "aucun courriel neuf"
    assert "Relève de la boîte : aucun courriel neuf" in journal.raconter()


def test_la_releve_automatique_ne_note_que_ce_qu_elle_voit(base):
    # Douze passages par jour : sans courriel neuf, elle ne s'inscrit pas.
    with operation.ouvrir("Relève des confirmations SNCF", acteur="ordonnanceur"):
        billets.relever(_id("thomas"), messages=[])

    assert evenements("releve") == []


# ---------------------------------------------------------------------------
# Trois mois, pas plus                                                   JRN-8
# ---------------------------------------------------------------------------

def test_le_journal_ne_garde_que_trois_mois(base):
    journal.noter("essai", "récent")
    journal.noter("essai", "ancien")
    sql("UPDATE evenement SET quand = now() - INTERVAL '91 days' WHERE libelle = 'ancien'")

    bilan = report_de_minuit()

    assert bilan["journal_purge"] == 1
    assert [e["libelle"] for e in evenements("essai")] == ["récent"]


# ---------------------------------------------------------------------------
# Les branchements                                                       JRN-4
# ---------------------------------------------------------------------------

def test_une_commande_du_bot_ouvre_une_action_a_son_nom(base):
    from api import bot

    appairage.appairer(CLE_THOMAS, 424242)
    vu = {}

    async def commande(update, contexte):
        await bot._appelant(update)
        en_cours = operation.courante()
        vu.update(origine=en_cours.origine, acteur=en_cours.acteur)

    update = SimpleNamespace(effective_user=SimpleNamespace(id=424242))
    asyncio.run(bot._suivie("absent", commande)(update, None))

    assert vu == {"origine": "bot : /absent", "acteur": "thomas"}
    # Et rien ne déborde sur la commande suivante.
    assert operation.courante() is None


def test_chaque_commande_du_catalogue_est_suivie():
    from api import bot

    branchees = dict(bot.gestionnaires())

    assert set(branchees) == {nom for _, nom, _, _, _ in bot.catalogue()}
    assert "etat" in branchees
    # `wraps` garde l'original sous la main : c'est la marque de l'enveloppe.
    assert all(hasattr(fonction, "__wrapped__") for fonction in branchees.values())


def test_une_tache_planifiee_agit_au_nom_de_l_ordonnanceur(base):
    from api.ordonnanceur import _Suivi

    vu = {}

    def tache():
        en_cours = operation.courante()
        vu.update(origine=en_cours.origine, acteur=en_cours.acteur)

    ordonnanceur = _Suivi()
    travail = ordonnanceur.add_job(tache, "date", name="Bilan du matin")
    travail.func()

    assert vu == {"origine": "Bilan du matin", "acteur": "ordonnanceur"}
