"""Le bot d'administration, testé sans Telegram.            (ADM-1 à ADM-5)

Le bot ne parle plus qu'à l'administrateur du serveur. Ce qu'il dit vit dans
`administration.py`, son appairage dans `appairage.py`. Ce que faisait le bot
des membres (`bot_des_membres.py`) se teste ici aussi.
"""

import asyncio
from datetime import datetime, timedelta
from types import SimpleNamespace
from unittest.mock import patch
from zoneinfo import ZoneInfo

import psycopg
import pytest

from api import administration, appairage, bot_des_membres
from tests.conftest import CLE_LORETTE, CLE_THOMAS, _url

PARIS = ZoneInfo("Europe/Paris")
TELEGRAM_THOMAS = 111222333
TELEGRAM_LORETTE = 444555777


@pytest.fixture(autouse=True)
def sans_appairage():
    """Chaque test repart d'un bot qui ne connaît personne, sans alerte en cours."""
    with psycopg.connect(_url(), autocommit=True) as conn:
        conn.execute("UPDATE utilisateur SET id_telegram = NULL")
        conn.execute("DELETE FROM alerte_admin")
        conn.execute("DELETE FROM notification WHERE type = 'administration'")
    administration.oublier_les_erreurs()
    yield


def sql(requete: str, *params):
    with psycopg.connect(_url(), autocommit=True) as conn:
        curseur = conn.execute(requete, params)
        return curseur.fetchall() if curseur.description else None


def id_de(pseudo: str) -> int:
    return sql("SELECT id_utilisateur FROM utilisateur WHERE pseudo = %s", pseudo)[0][0]


# ---------------------------------------------------------------------------
# Appairage                                                             (ADM-5)
# ---------------------------------------------------------------------------

def test_la_cle_de_l_administrateur_relie_le_bot(base):
    compte = appairage.appairer(CLE_THOMAS, TELEGRAM_THOMAS)
    assert compte is not None
    assert compte["pseudo"] == "thomas"

    assert appairage.compte_de(TELEGRAM_THOMAS)["pseudo"] == "thomas"


def test_la_cle_d_un_membre_ne_relie_rien(base):
    assert appairage.appairer(CLE_LORETTE, TELEGRAM_LORETTE) is None
    assert appairage.compte_de(TELEGRAM_LORETTE) is None


def test_une_cle_inconnue_n_appaire_rien(base):
    assert appairage.appairer("X" * 48, TELEGRAM_THOMAS) is None
    assert appairage.compte_de(TELEGRAM_THOMAS) is None


def test_un_inconnu_n_est_relie_a_aucun_compte(base):
    assert appairage.compte_de(999999) is None


def test_on_peut_changer_de_telephone(base):
    appairage.appairer(CLE_THOMAS, TELEGRAM_THOMAS)
    appairage.appairer(CLE_THOMAS, 444555666)

    assert appairage.compte_de(TELEGRAM_THOMAS) is None
    assert appairage.compte_de(444555666)["pseudo"] == "thomas"


def test_delier_le_compte(base):
    appairage.appairer(CLE_THOMAS, TELEGRAM_THOMAS)
    assert appairage.desappairer(TELEGRAM_THOMAS) is True
    assert appairage.compte_de(TELEGRAM_THOMAS) is None


def test_la_migration_delie_les_membres_et_garde_l_administrateur(base):
    """ADM-5 : rejouée, la migration ne laisse que l'administrateur relié."""
    from pathlib import Path

    sql("UPDATE utilisateur SET id_telegram = 1 WHERE pseudo = 'thomas'")
    sql("UPDATE utilisateur SET id_telegram = 2 WHERE pseudo = 'lorette'")
    migration = Path(__file__).parent.parent / "sql" / "064_bot_d_administration.sql"
    with psycopg.connect(_url(), autocommit=True) as conn:
        # La migration réécrit la liste des types de notification telle qu'elle
        # était en 064 : les suivantes en ont ajouté. On la remet après coup,
        # pour ne pas fausser les tests qui passent ensuite.
        types, = conn.execute(
            "SELECT pg_get_constraintdef(oid) FROM pg_constraint"
            " WHERE conname = 'notification_type_check'").fetchone()
        conn.execute(migration.read_text())
        conn.execute("ALTER TABLE notification DROP CONSTRAINT notification_type_check;"
                     f"ALTER TABLE notification ADD CONSTRAINT notification_type_check {types}")

    relies = dict(sql("SELECT pseudo, id_telegram FROM utilisateur"
                      " WHERE pseudo IN ('thomas', 'lorette')"))
    assert relies == {"thomas": 1, "lorette": None}


# ---------------------------------------------------------------------------
# Heures de silence
# ---------------------------------------------------------------------------

def test_pas_de_notification_la_nuit():
    # Faire vibrer un téléphone à 3h du matin pour une poussière est le meilleur
    # moyen de faire couper les notifications.
    assert bot_des_membres.en_silence(datetime(2026, 8, 20, 3, 0, tzinfo=PARIS))
    assert bot_des_membres.en_silence(datetime(2026, 8, 20, 23, 45, tzinfo=PARIS))
    assert bot_des_membres.en_silence(datetime(2026, 8, 20, 7, 0, tzinfo=PARIS))


def test_la_journee_n_est_pas_silencieuse():
    assert not bot_des_membres.en_silence(datetime(2026, 8, 20, 7, 30, tzinfo=PARIS))
    assert not bot_des_membres.en_silence(datetime(2026, 8, 20, 12, 0, tzinfo=PARIS))
    assert not bot_des_membres.en_silence(datetime(2026, 8, 20, 21, 0, tzinfo=PARIS))
    assert not bot_des_membres.en_silence(datetime(2026, 8, 20, 23, 29, tzinfo=PARIS))


def test_le_silence_se_termine_le_lendemain_matin():
    prochain = bot_des_membres.prochain_rappel(1)
    assert prochain > datetime.now(PARIS)
    assert prochain.astimezone(PARIS).hour == 7


# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

def occurrence_de(client, thomas, code: str) -> dict:
    toutes = client.get("/occurrences", headers=thomas).json()
    return next(o for o in toutes if o["tache_code"] == code)


def test_le_bouton_fait_valide_l_occurrence(client, thomas, base):
    client.post("/planning/placer", headers=thomas)
    aspirateur = occurrence_de(client, thomas, "ASPIRATEUR")
    compte = {"id_utilisateur": id_de("thomas")}

    reponse = bot_des_membres.executer_action("valider", aspirateur["id_occurrence"],
                                   compte["id_utilisateur"])
    assert "noté" in reponse

    apres = client.get(f"/occurrences/{aspirateur['id_occurrence']}", headers=thomas).json()
    assert apres["statut"] == "faite"


def test_le_bouton_plus_tard_repousse(client, thomas, base):
    client.post("/planning/placer", headers=thomas)
    aspirateur = occurrence_de(client, thomas, "ASPIRATEUR")
    compte = {"id_utilisateur": id_de("thomas")}

    reponse = bot_des_membres.executer_action("reporter", aspirateur["id_occurrence"],
                                   compte["id_utilisateur"])
    assert "demain" in reponse

    apres = client.get(f"/occurrences/{aspirateur['id_occurrence']}", headers=thomas).json()
    assert apres["statut"] == "a_placer"


def test_une_tache_non_reportable_refuse_d_etre_repoussee(client, thomas, base):
    client.post("/planning/placer", headers=thomas)
    lessive = occurrence_de(client, thomas, "LITIERE_CROTTES")
    compte = {"id_utilisateur": id_de("thomas")}

    reponse = bot_des_membres.executer_action("reporter", lessive["id_occurrence"],
                                   compte["id_utilisateur"])
    assert "ne résoudrait rien" in reponse

    apres = client.get(f"/occurrences/{lessive['id_occurrence']}", headers=thomas).json()
    assert apres["statut"] != "a_placer"


def test_le_bouton_non_recree_la_tache_sans_assigne(client, thomas, base):
    client.post("/planning/placer", headers=thomas)
    aspirateur = occurrence_de(client, thomas, "ASPIRATEUR")
    compte = {"id_utilisateur": id_de("thomas")}

    reponse = bot_des_membres.executer_action("refuser", aspirateur["id_occurrence"],
                                   compte["id_utilisateur"])
    assert "sans assigné" in reponse

    apres = client.get(f"/occurrences/{aspirateur['id_occurrence']}", headers=thomas).json()
    assert apres["statut"] == "abandonnee"


def test_une_action_inconnue_est_refusee(base):
    with pytest.raises(ValueError):
        bot_des_membres.executer_action("supprimer", 1, 1)


def test_valider_deux_fois_remonte_le_refus_de_la_base(client, thomas, base):
    client.post("/planning/placer", headers=thomas)
    aspirateur = occurrence_de(client, thomas, "ASPIRATEUR")
    compte = {"id_utilisateur": id_de("thomas")}

    valider = bot_des_membres.executer_action
    valider("valider", aspirateur["id_occurrence"], compte["id_utilisateur"])

    with pytest.raises(psycopg.Error) as erreur:
        valider("valider", aspirateur["id_occurrence"], compte["id_utilisateur"])
    # Le message de la base est déjà rédigé en français : le bot le montrera tel quel.
    assert "close" in erreur.value.diag.message_primary


# ---------------------------------------------------------------------------
# Mise en forme
# ---------------------------------------------------------------------------

def test_le_planning_du_jour_separe_horaires_et_rappels(client, thomas, base):
    debut = datetime.now(PARIS).replace(hour=14, minute=0, second=0, microsecond=0)
    client.post("/occupations", headers=thomas, json={
        "type": "cours", "libelle": "Cours IDMC",
        "debut": debut.isoformat(), "fin": (debut + timedelta(hours=2)).isoformat(),
        "lieu": "Salle 104",
    })
    client.post("/planning/placer", headers=thomas)

    # Le moteur étale les tâches : rien ne garantit qu'un rappel tombe
    # aujourd'hui. On en force un, sinon le test dépendrait du calendrier.
    from tests.test_boucle_quotidienne import forcer_au_jour_meme
    forcer_au_jour_meme("ASPIRATEUR")

    compte = {"id_utilisateur": id_de("thomas")}
    texte = bot_des_membres.planning_du_jour(compte["id_utilisateur"])

    assert "14h00–16h00  Cours IDMC — Salle 104" in texte
    # Les rappels sans heure sont listés à part, avec une puce. L'aspirateur
    # peut y porter le titre de son bloc, « Nettoyage 2/3 : … » (TAC-16).
    assert any(ligne.startswith("○ ") and ligne.endswith("Passer l'aspirateur")
               for ligne in texte.splitlines()), texte


def test_un_planning_vide_le_dit(base):
    compte = {"id_utilisateur": id_de("thomas")}
    assert bot_des_membres.planning_du_jour(compte["id_utilisateur"],
                                            dans_jours=300) == "Rien de prévu."



# ---------------------------------------------------------------------------
# Catalogue des commandes
#
# L'aide était écrite à la main à côté des handlers : elle avait fini par
# oublier /demarrer et /aide elle-même. Ces tests interdisent la dérive.
# ---------------------------------------------------------------------------

# /start et /help sont des alias que Telegram propose de lui-même. Ils ne sont
# pas des commandes de plus et n'ont pas à figurer dans l'aide.
ALIAS = {"start", "help"}


def _commandes_enregistrees(monkeypatch) -> set[str]:
    """Les commandes que `construire()` branche vraiment.

    On construit l'application pour de bon, avec un jeton de façade : `build()`
    ne parle pas à Telegram. Lire le source ne suffirait plus, les commandes
    étant branchées dans une boucle sur le catalogue.
    """
    from api import bot

    class _Config:
        telegram_token = "123456:AAAA-jeton-de-facade"

    monkeypatch.setattr(bot, "configuration", lambda: _Config())
    application = bot.construire()

    noms: set[str] = set()
    for groupe in application.handlers.values():
        for handler in groupe:
            noms |= set(getattr(handler, "commands", ()) or ())
    return noms


def test_toute_commande_branchee_figure_dans_l_aide(monkeypatch):
    from api import bot

    au_catalogue = {nom for _, nom, _, _, _ in bot.catalogue()}
    branchees = _commandes_enregistrees(monkeypatch) - ALIAS

    assert branchees <= au_catalogue, (
        f"commandes branchées mais absentes de l'aide : {branchees - au_catalogue}")


# Le sens inverse, une commande annoncée qui ne répondrait pas, n'a pas de test :
# c'est le catalogue qui branche les handlers, il est donc impossible d'annoncer
# une commande sans la brancher. Un test qui ne peut pas échouer ne prouve rien.


def test_le_catalogue_tient_debout():
    from api import bot

    noms = [nom for _, nom, _, _, _ in bot.catalogue()]
    assert len(noms) == len(set(noms)), "une commande apparaît deux fois"

    for _, nom, _, _, fonction in bot.catalogue():
        assert callable(fonction), f"{nom} ne pointe sur rien d'appelable"


def test_les_noms_sont_acceptables_par_telegram():
    import re

    from api import bot

    # Telegram n'accepte que des minuscules, des chiffres et des tirets bas,
    # sur 32 caractères au plus. Un nom accentué serait refusé à la publication
    # du menu, et le menu entier avec lui.
    for commande in bot.commandes_telegram():
        assert re.fullmatch(r"[a-z0-9_]{1,32}", commande.command), commande.command
        assert 1 <= len(commande.description) <= 256, commande.command


def test_l_aide_groupe_et_n_oublie_personne():
    from api import bot

    texte = bot.texte_aide()
    for _, nom, _, _, _ in bot.catalogue():
        assert f"/{nom}" in texte, f"/{nom} manque dans l'aide"

    groupes = {groupe for groupe, _, _, _, _ in bot.catalogue()}
    for groupe in groupes:
        assert f"<b>{groupe}</b>" in texte



def test_seules_les_commandes_de_l_administration_restent():
    """ADM-3 : la liste exacte des commandes gardées."""
    from api import bot

    noms = {nom for _, nom, _, _, _ in bot.catalogue()}
    assert noms == {"etat", "erreurs", "collecter", "placer", "billets", "hal",
                    "demarrer", "aide"}


# ---------------------------------------------------------------------------
# Les handlers, joués pour de vrai                                       (ADM-1)
# ---------------------------------------------------------------------------

class _Message:
    """Le message Telegram : retient ce qu'on y répond."""

    def __init__(self, journal: list):
        self.journal = journal
        self.text = "Ancien message"

    async def reply_text(self, texte, reply_markup=None, parse_mode=None):
        self.journal.append(("nouveau", texte, reply_markup))


class _Requete:
    """Un appui sur un bouton : retient si l'écran est remplacé."""

    def __init__(self, data: str, journal: list):
        self.data = data
        self.journal = journal
        self.message = _Message(journal)

    async def answer(self):
        pass

    async def edit_message_text(self, texte, reply_markup=None, parse_mode=None):
        self.journal.append(("remplace", texte, reply_markup))


def _jouer(handler, qui: int, rappel: str | None = None, args=()) -> list:
    journal: list = []
    requete = _Requete(rappel, journal) if rappel else None
    update = SimpleNamespace(
        effective_user=SimpleNamespace(id=qui),
        effective_chat=SimpleNamespace(id=qui),
        effective_message=requete.message if requete else _Message(journal),
        callback_query=requete,
    )
    asyncio.run(handler(update, SimpleNamespace(args=list(args))))
    return journal


def _textes(journal: list) -> list[str]:
    return [texte for _, texte, _ in journal]


def test_un_membre_recoit_la_phrase_d_adm_1(base):
    """La vérification du lot 2 : un message d'un autre compte au bot."""
    from api import bot

    sql("UPDATE utilisateur SET id_telegram = %s WHERE pseudo = 'lorette'", TELEGRAM_LORETTE)
    for handler in (bot.texte_libre, bot.etat, bot.erreurs, bot.placer, bot.hal, bot.aide):
        assert _textes(_jouer(handler, TELEGRAM_LORETTE)) == [administration.PHRASE_AUX_MEMBRES]


def test_un_inconnu_recoit_la_meme_phrase(base):
    from api import bot

    assert _textes(_jouer(bot.texte_libre, 987654)) == [administration.PHRASE_AUX_MEMBRES]
    assert _textes(_jouer(bot.demarrer, 987654)) == [administration.PHRASE_AUX_MEMBRES]


def test_un_membre_ne_se_relie_pas_avec_sa_cle(base):
    from api import bot

    journal = _jouer(bot.demarrer, TELEGRAM_LORETTE, args=[CLE_LORETTE])
    assert _textes(journal) == [administration.PHRASE_AUX_MEMBRES]
    assert appairage.compte_de(TELEGRAM_LORETTE) is None


def test_l_administrateur_se_relie_et_lit_l_aide(base):
    from api import bot

    journal = _jouer(bot.demarrer, TELEGRAM_THOMAS, args=[CLE_THOMAS])
    assert "Bonjour thomas" in _textes(journal)[0]
    assert "/etat" in _textes(journal)[0]
    assert appairage.compte_de(TELEGRAM_THOMAS)["pseudo"] == "thomas"


def test_un_bouton_d_un_membre_recoit_la_phrase(base):
    from api import bot

    sql("UPDATE utilisateur SET id_telegram = %s WHERE pseudo = 'lorette'", TELEGRAM_LORETTE)
    journal = _jouer(bot.bouton, TELEGRAM_LORETTE, rappel="tache:valider:1")
    assert _textes(journal) == [administration.PHRASE_AUX_MEMBRES]


def test_un_ancien_bouton_renvoie_a_l_appli(base):
    from api import bot

    appairage.appairer(CLE_THOMAS, TELEGRAM_THOMAS)
    journal = _jouer(bot.bouton, TELEGRAM_THOMAS, rappel="sp:sem:20261012")
    assert "l'appli HAL" in _textes(journal)[0]


def test_etat_dit_le_serveur_les_sources_et_les_alertes(base):
    from api import bot

    appairage.appairer(CLE_THOMAS, TELEGRAM_THOMAS)
    administration.alerter("disque", "Le disque est plein à 95 %.")
    texte = _textes(_jouer(bot.etat, TELEGRAM_THOMAS))[0]
    assert "Base : répond" in texte
    assert "<b>Sources</b>" in texte
    assert "Le disque est plein à 95 %." in texte


def test_erreurs_lit_ce_que_l_api_a_journalise(base):
    import logging

    from api import bot

    appairage.appairer(CLE_THOMAS, TELEGRAM_THOMAS)
    administration.installer()
    logging.getLogger("api.essai").error("Quelque chose a cassé <ici>")
    texte = _textes(_jouer(bot.erreurs, TELEGRAM_THOMAS))[0]
    assert "Quelque chose a cassé &lt;ici&gt;" in texte
    assert "api.essai" in texte


def test_hal_donne_chaque_compte_et_se_regle(base):
    from api import bot

    appairage.appairer(CLE_THOMAS, TELEGRAM_THOMAS)
    texte = _textes(_jouer(bot.hal, TELEGRAM_THOMAS))[0]
    assert "<b>thomas</b>" in texte and "<b>lorette</b>" in texte

    _jouer(bot.hal, TELEGRAM_THOMAS, args=["lorette", "off"])
    assert sql("SELECT coach_actif FROM utilisateur WHERE pseudo = 'lorette'")[0][0] is False


# ---------------------------------------------------------------------------
# Les alertes                                                    (ADM-2, ADM-4)
# ---------------------------------------------------------------------------

class _BotFactice:
    """Retient ce que le bot aurait envoyé, sans parler à Telegram."""

    def __init__(self):
        self.envois: list[dict] = []

    async def send_message(self, chat_id, texte, reply_markup=None, parse_mode=None):
        self.envois.append({"chat": chat_id, "texte": texte})


def _vider_la_file() -> list[dict]:
    from api import bot

    factice = _BotFactice()
    asyncio.run(bot.vider_la_file(SimpleNamespace(bot=factice)))
    return factice.envois


def test_une_alerte_ne_se_repete_pas_dans_l_heure(base):
    assert administration.alerter("disque", "Disque plein") is True
    assert administration.alerter("disque", "Disque toujours plein") is False

    # Une heure plus tard, elle se redit.
    sql("UPDATE alerte_admin SET annoncee_le = now() - INTERVAL '61 minutes'")
    assert administration.alerter("disque", "Disque toujours plein") is True
    assert sql("SELECT count(*) FROM notification WHERE type = 'administration'")[0][0] == 2


def test_une_source_en_panne_ne_se_redit_qu_une_fois_par_jour(base):
    # ADM-4 : une source en panne n'empêche rien de tourner. La redire toutes
    # les heures faisait des dizaines de messages par jour pour un seul calendrier.
    assert administration.alerter("source:ADE", "ADE en panne") is True
    sql("UPDATE alerte_admin SET annoncee_le = now() - INTERVAL '5 hours'")
    assert administration.alerter("source:ADE", "ADE toujours en panne") is False

    sql("UPDATE alerte_admin SET annoncee_le = now() - INTERVAL '25 hours'")
    assert administration.alerter("source:ADE", "ADE toujours en panne") is True
    assert sql("SELECT count(*) FROM notification WHERE type = 'administration'")[0][0] == 2


def test_un_probleme_regle_se_dit_une_fois(base):
    assert administration.lever("apple", "Réglé") is False
    administration.alerter("apple", "Apple refuse")
    assert administration.lever("apple", "Réglé") is True
    assert administration.lever("apple", "Réglé") is False
    # Un nouveau problème rouvre l'alerte.
    assert administration.alerter("apple", "Apple refuse encore") is True


def test_le_bot_n_envoie_que_les_alertes_de_l_administration(client, thomas, base):
    """ADM-5 : le bilan du matin, les rappels, HAL passent par l'appli."""
    client.post("/planning/placer", headers=thomas)
    client.post("/notifications/bilan", headers=thomas)
    appairage.appairer(CLE_THOMAS, TELEGRAM_THOMAS)
    sql("UPDATE utilisateur SET id_telegram = %s WHERE pseudo = 'lorette'", TELEGRAM_LORETTE)

    administration.alerter("disque", "Le disque est plein.")
    envois = _vider_la_file()
    assert [e["texte"] for e in envois] == ["Le disque est plein."]
    assert envois[0]["chat"] == TELEGRAM_THOMAS
    assert _vider_la_file() == []


def test_une_alerte_ne_part_jamais_par_apple(base):
    administration.alerter("disque", "Le disque est plein.")
    assert sql("SELECT apple_statut FROM notification WHERE type = 'administration'") \
        == [("perimee",)]


def test_un_echec_d_envoi_conserve_l_alerte(base):
    appairage.appairer(CLE_THOMAS, TELEGRAM_THOMAS)
    administration.alerter("disque", "Le disque est plein.")
    notification = administration.notifications_a_envoyer()[0]
    administration.marquer_envoyee(notification["id_notification"], reussi=False)

    assert administration.notifications_a_envoyer() == []
    assert sql("SELECT statut FROM notification WHERE id_notification = %s",
               notification["id_notification"]) == [("echec",)]


def test_la_surveillance_previent_pour_une_source_en_panne(base):
    sql("UPDATE source SET derniere_collecte = now() - INTERVAL '30 days',"
        " url = COALESCE(url, 'https://exemple.invalid') WHERE mode_collecte <> 'manuelle'")
    assert administration.surveiller() == []
    textes = [t for (t,) in sql("SELECT contenu FROM notification WHERE type = 'administration'")]
    assert any("ne se collecte plus" in t for t in textes)


def test_des_erreurs_en_serie_previennent(base):
    import logging

    administration.installer()
    for rang in range(administration.ERREURS_AVANT_ALERTE):
        logging.getLogger("api.essai").error("Erreur %s", rang)
    with patch.object(administration, "_sources"), patch.object(administration, "_disque"):
        administration.surveiller()
    textes = [t for (t,) in sql("SELECT contenu FROM notification WHERE type = 'administration'")]
    assert any("erreurs de l'API en dix minutes" in t for t in textes)


def test_apple_qui_refuse_previent_puis_se_leve(base):
    administration.apres_l_envoi_par_apple({"echecs": 2, "envoyees": 0})
    administration.apres_l_envoi_par_apple({"echecs": 0, "envoyees": 3})
    textes = [t for (t,) in sql("SELECT contenu FROM notification WHERE type = 'administration'"
                                " ORDER BY id_notification")]
    assert len(textes) == 2 and "refusé" in textes[0] and "de nouveau" in textes[1]
