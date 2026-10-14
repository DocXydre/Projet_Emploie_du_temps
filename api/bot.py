"""Bot Telegram d'administration : commandes, boutons, envoi des alertes.

ADM-1 : le bot ne parle qu'à l'administrateur du serveur. Les membres du foyer
ont tout dans l'appli HAL ; un message d'un autre compte reçoit une seule
phrase, toujours la même.

Ce module ne contient que du branchement. Ce que le bot dit vit dans
`administration.py`, qui se teste sans parler à Telegram. Le bot des membres,
tel qu'il était, est rangé dans `anciennes_fonctionnalites/bot_des_membres/`.

Le bot tourne dans le processus de l'API. Sans jeton, il ne démarre pas et le
reste fonctionne, les alertes restant en file.
"""

from __future__ import annotations

import asyncio
import logging
from functools import wraps

from telegram import BotCommand, InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.constants import ParseMode
from telegram.ext import (
    Application,
    CallbackQueryHandler,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

from api import administration, billets, operation, trajets
from api import conversation as conv
from api.collecteurs.courriel import BoiteIndisponible
from api.config import configuration

LOG = logging.getLogger(__name__)

_application: Application | None = None
_identite: dict | None = None
# Tâche de fond qui réessaie de joindre Telegram tant que le bot n'est pas en
# ligne. Gardée pour pouvoir l'annuler à l'arrêt de l'API.
_reconnexion: asyncio.Task | None = None


async def _appelant(update: Update) -> dict | None:
    """Compte associé à cette conversation, ou None si non appairé."""
    if update.effective_user is None:
        return None
    compte = await asyncio.to_thread(conv.compte_de, update.effective_user.id)
    if compte is not None:
        # JRN-4 : ce que cette commande changera sera noté à son nom.
        operation.signer(compte["pseudo"])
    return compte


async def _administrateur(update: Update) -> dict | None:
    """L'administrateur du serveur, ou None après lui avoir répondu la phrase d'ADM-1."""
    compte = await _appelant(update)
    if administration.est_administrateur(compte):
        return compte
    if update.callback_query is not None:
        await update.callback_query.answer()
    if update.effective_message is not None:
        await update.effective_message.reply_text(administration.PHRASE_AUX_MEMBRES)
    return None


def reserve(fonction):
    """ADM-1 : une commande que seul l'administrateur du serveur atteint."""
    @wraps(fonction)
    async def enveloppe(update: Update, contexte: ContextTypes.DEFAULT_TYPE):
        compte = await _administrateur(update)
        if compte is None:
            return None
        return await fonction(update, contexte, compte)

    return enveloppe


async def _repondre(update: Update, texte: str) -> None:
    """Un message HTML, coupé sous la limite de Telegram."""
    await update.effective_message.reply_text(texte[:4090], parse_mode=ParseMode.HTML)


# ---------------------------------------------------------------------------
# Commandes
# ---------------------------------------------------------------------------

async def demarrer(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    """Relier ce compte Telegram. Seule la clé de l'administrateur relie (ADM-5)."""
    compte = await _appelant(update)
    if administration.est_administrateur(compte):
        await _repondre(update, f"Bonjour {compte['pseudo']}.\n\n{texte_aide()}")
        return
    if not contexte.args:
        await update.effective_message.reply_text(administration.PHRASE_AUX_MEMBRES)
        return

    compte = await asyncio.to_thread(conv.appairer, contexte.args[0],
                                     update.effective_user.id)
    if compte is None:
        # La même phrase pour une clé inconnue et pour un membre : inutile de
        # dire laquelle des deux à quelqu'un qui essaie des clés au hasard.
        await update.effective_message.reply_text(administration.PHRASE_AUX_MEMBRES)
        return
    await _repondre(update, f"Bonjour {compte['pseudo']}. Je te préviendrai quand "
                            f"quelque chose casse.\n\n{texte_aide()}")


@reserve
async def aide(update: Update, contexte: ContextTypes.DEFAULT_TYPE, compte: dict) -> None:
    await _repondre(update, texte_aide())


@reserve
async def etat(update: Update, contexte: ContextTypes.DEFAULT_TYPE, compte: dict) -> None:
    from api import ordonnanceur

    texte = await asyncio.to_thread(administration.etat, ordonnanceur.taches_programmees())
    if _identite:
        texte = texte.replace("\n", f"\nBot : {_identite['identifiant']}\n", 1)
    await _repondre(update, texte)


@reserve
async def erreurs(update: Update, contexte: ContextTypes.DEFAULT_TYPE, compte: dict) -> None:
    await _repondre(update, administration.erreurs_en_clair())


@reserve
async def collecter(update: Update, contexte: ContextTypes.DEFAULT_TYPE, compte: dict) -> None:
    from api.collecteurs.service import CollecteImpossible, collecter_source, sources_a_collecter

    # Demandée à la main, la collecte ne regarde pas la fréquence : on la
    # demande justement parce qu'on attend un changement tout de suite.
    codes = contexte.args or await asyncio.to_thread(sources_a_collecter, True)
    if not codes:
        await update.effective_message.reply_text(
            "Aucun flux à collecter : aucune source active n'a d'adresse.")
        return

    for code in codes:
        try:
            bilan = await asyncio.to_thread(collecter_source, code, compte["id_utilisateur"])
        except CollecteImpossible as erreur:
            await update.effective_message.reply_text(f"{code} : {erreur.message}")
            continue

        texte = (f"{code} : {bilan['crees']} nouveau(x), "
                 f"{bilan['mis_a_jour']} mis à jour, {bilan['annules']} retiré(s).")
        if not (bilan["crees"] or bilan["mis_a_jour"] or bilan["annules"]):
            texte += f"\n{bilan['lues']} événement(s) lus, rien n'a changé."
        await update.effective_message.reply_text(texte)


@reserve
async def placer(update: Update, contexte: ContextTypes.DEFAULT_TYPE, compte: dict) -> None:
    from api import ordonnanceur

    try:
        placees = await asyncio.to_thread(ordonnanceur.placer)
    except Exception as erreur:  # noqa: BLE001 - la base dit pourquoi
        await update.effective_message.reply_text(_message_lisible(erreur))
        return
    await update.effective_message.reply_text(f"Placement fait : {placees} occurrence(s).")


@reserve
async def commande_billets(update: Update, contexte: ContextTypes.DEFAULT_TYPE,
                           compte: dict) -> None:
    """Relève la boîte, puis liste les voyages qui en sont issus.

    Chaque absence née d'un courriel porte un bouton pour l'annuler : le
    lecteur peut se tromper, et se tromper en silence gèlerait deux jours de
    ménage sans que personne ne comprenne.
    """
    # BIL-19 : « /billets relire » repart de zéro. À faire après une correction
    # du lecteur, sans quoi les courriels mal lus mais classés « traités » ne
    # reviennent jamais.
    if contexte.args and contexte.args[0].lower() in ("relire", "tout", "oublier"):
        efface = await asyncio.to_thread(billets.relire_les_billets)
        await update.effective_message.reply_text(
            f"Mémoire effacée : {efface['courriels_oublies']} courriel(s) à relire, "
            f"{efface['absences_rendues']} absence(s) rendue(s) au ménage.")

    try:
        bilan = await asyncio.to_thread(billets.relever, compte["id_utilisateur"])
    except BoiteIndisponible as erreur:
        await update.effective_message.reply_text(erreur.message)
        return

    await update.effective_message.reply_text(billets.resume(bilan))

    for revoir in await asyncio.to_thread(billets.a_revoir, 5):
        await update.effective_message.reply_text(
            f"Non exploité : {revoir['sujet'] or 'sans sujet'}\n{revoir['motif']}")

    voyages = await asyncio.to_thread(billets.absences_issues_de_billets)
    for voyage in voyages:
        refs = voyage.get("references") or ""
        titre = "Billets" if "," in refs else "Billet"
        await update.effective_message.reply_text(
            f"{titre}{f' ({refs})' if refs else ''} "
            f": absent du {conv._jour(voyage['debut'])} "
            f"au {conv._jour(voyage['fin'])}"
            f"{' à ' + voyage['lieu'] if voyage['lieu'] else ''}"
            # TRJ-7 : sans billet de retour, la fin est une supposition.
            f"{'' if voyage.get('retour_connu') else ' (retour à confirmer)'}",
            reply_markup=InlineKeyboardMarkup([[
                InlineKeyboardButton(
                    "Ce n'est pas ça, annule",
                    callback_data=f"billet:annuler:{voyage['id_absence']}"),
            ]]),
        )

    if not voyages and bilan["traites"] == 0:
        await update.effective_message.reply_text(
            "Aucun voyage déclaré par courriel pour l'instant.")


@reserve
async def hal(update: Update, contexte: ContextTypes.DEFAULT_TYPE, compte: dict) -> None:
    """L'état de HAL par compte, et ce qu'il a consommé (l'ancienne /coach)."""
    arguments = [a.lower() for a in (contexte.args or [])]
    if len(arguments) == 2 and arguments[1] in ("on", "off"):
        texte = await asyncio.to_thread(administration.regler_hal, arguments[0],
                                        arguments[1] == "on")
        await _repondre(update, texte)
        return
    await _repondre(update, await asyncio.to_thread(administration.hal_en_clair))


async def texte_libre(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    """Un message qui n'est pas une commande : l'aide pour l'administrateur,
    la phrase d'ADM-1 pour tout autre compte."""
    if update.effective_message is None:
        return
    compte = await _administrateur(update)
    if compte is not None:
        await _repondre(update, texte_aide())


# ---------------------------------------------------------------------------
# Boutons
# ---------------------------------------------------------------------------

async def bouton(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    requete = update.callback_query
    compte = await _appelant(update)
    if not administration.est_administrateur(compte):
        await requete.answer()
        await requete.edit_message_text(administration.PHRASE_AUX_MEMBRES)
        return
    await requete.answer()

    genre, choix, identifiant = (requete.data.split(":", 2) + ["", ""])[:3]
    if genre == "billet":
        operation.preciser("bot : bouton Annuler le billet")
        try:
            replacees = await asyncio.to_thread(trajets.oublier, int(identifiant))
            reponse = (f"Annulé, les tâches reviennent "
                       f"({replacees} occurrence(s) replacée(s)).")
        except Exception as erreur:  # noqa: BLE001 - la base dit pourquoi
            reponse = _message_lisible(erreur)
        await requete.edit_message_text(f"{requete.message.text}\n\n→ {reponse}")
        return

    # Les boutons de l'ancien bot, restés dans la conversation.
    await requete.edit_message_text(
        f"{requete.message.text}\n\n→ Ce bouton date de l'ancien bot. Tout se fait "
        "maintenant dans l'appli HAL.")


def _message_lisible(erreur: Exception) -> str:
    diag = getattr(erreur, "diag", None)
    if diag is not None and diag.message_primary:
        return diag.message_primary
    LOG.exception("Action impossible")
    return "Impossible pour l'instant."


# ---------------------------------------------------------------------------
# Envoi de la file                                                (ADM-2, ADM-5)
#
# Seules les alertes de l'administration partent par le bot. Les notifications
# des membres, celles de l'administrateur compris, passent par l'appli.
# ---------------------------------------------------------------------------

async def vider_la_file(contexte: ContextTypes.DEFAULT_TYPE) -> None:
    with operation.ouvrir("envoi des alertes", acteur="bot"):
        await _envoyer_la_file(contexte)


async def _envoyer_la_file(contexte: ContextTypes.DEFAULT_TYPE) -> None:
    for notification in await asyncio.to_thread(conv.notifications_a_envoyer, 20):
        try:
            await contexte.bot.send_message(notification["id_telegram"],
                                            notification["contenu"][:4090])
            await asyncio.to_thread(conv.marquer_envoyee, notification["id_notification"], True)
        except Exception:
            # NOT-2 : un échec d'envoi laisse la notification en attente.
            LOG.warning("Envoi impossible, alerte %s conservée",
                        notification["id_notification"])
            await asyncio.to_thread(conv.marquer_envoyee, notification["id_notification"], False)


# ---------------------------------------------------------------------------
# Catalogue des commandes                                               (ADM-3)
#
# Une seule liste pour trois usages : l'enregistrement des handlers, le texte
# de /aide, et le menu que Telegram propose quand on tape « / ».
# ---------------------------------------------------------------------------

def catalogue() -> list[tuple[str, str, str, str, object]]:
    """Groupe, nom, argument, description, fonction. Dans l'ordre d'affichage."""
    return [
        ("Le serveur", "etat", "", "le serveur, les sources, le dernier déploiement", etat),
        ("Le serveur", "erreurs", "", "les dernières erreurs de l'API", erreurs),
        ("Le serveur", "collecter", "", "forcer une collecte des emplois du temps",
         collecter),
        ("Le serveur", "placer", "", "relancer le placement des tâches", placer),
        ("Le serveur", "billets", "relire",
         "relever les confirmations SNCF, ou tout relire", commande_billets),
        ("Le serveur", "hal", "pseudo on",
         "l'état de HAL par compte et ce qu'il a consommé", hal),

        ("Ce compte", "demarrer", "TA_CLE_API", "relier ce compte Telegram", demarrer),
        ("Ce compte", "aide", "", "cette liste", aide),
    ]


def texte_aide() -> str:
    """L'aide, groupée et en HTML."""
    lignes: list[str] = []
    groupe_courant = ""

    for groupe, nom, argument, description, _ in catalogue():
        if groupe != groupe_courant:
            if lignes:
                lignes.append("")
            lignes.append(f"<b>{groupe}</b>")
            groupe_courant = groupe

        appel = f"/{nom} {argument}".rstrip()
        lignes.append(f"{appel} : {description}")

    lignes.append("\nTout le reste se fait dans l'appli HAL.")
    return "\n".join(lignes)


def commandes_telegram() -> list[BotCommand]:
    """Ce que Telegram propose à la saisie d'un « / »."""
    return [
        BotCommand(nom, f"{description} ({argument})" if argument else description)
        for _, nom, argument, description, _ in catalogue()
    ]


def _suivie(nom: str, fonction):
    """JRN-4 : chaque commande est une action du journal."""
    @wraps(fonction)
    async def enveloppe(update: Update, contexte: ContextTypes.DEFAULT_TYPE):
        origine = f"bot : {nom}" if nom in ("bouton", "message") else f"bot : /{nom}"
        with operation.ouvrir(origine):
            return await fonction(update, contexte)

    return enveloppe


def gestionnaires() -> list[tuple[str, object]]:
    """Les commandes telles qu'elles sont branchées : chacune dans son action."""
    return [(nom, _suivie(nom, fonction)) for _, nom, _, _, fonction in catalogue()]


def construire() -> Application:
    application = Application.builder().token(configuration().telegram_token).build()

    for nom, fonction in gestionnaires():
        application.add_handler(CommandHandler(nom, fonction))

    # /start à la première ouverture, /help par habitude : deux alias, pas des
    # commandes de plus.
    application.add_handler(CommandHandler("start", demarrer))
    application.add_handler(CommandHandler("help", aide))
    application.add_handler(CallbackQueryHandler(_suivie("bouton", bouton)))
    # ADM-1 : tout le reste, commandes de l'ancien bot comprises.
    application.add_handler(MessageHandler(filters.ALL, _suivie("message", texte_libre)))

    if application.job_queue is not None:
        application.job_queue.run_repeating(vider_la_file, interval=60, first=15)

    return application


async def _publier_les_commandes() -> None:
    """Donne à Telegram la liste à proposer quand on tape « / ».

    Un échec ici ne vaut pas un échec de démarrage : le bot répond aux mêmes
    commandes, elles ne s'affichent simplement pas toutes seules.
    """
    try:
        await _application.bot.set_my_commands(commandes_telegram())
    except Exception as erreur:  # noqa: BLE001 - le menu n'est pas vital
        LOG.warning("Menu des commandes non publié : %s", erreur)


async def _tenter_demarrage() -> bool:
    """Une tentative de connexion à Telegram. Vrai si le bot est en ligne."""
    global _application, _identite

    _application = construire()
    try:
        await _application.initialize()
        moi = await _application.bot.get_me()
        await _application.start()
        await _application.updater.start_polling(drop_pending_updates=True)
        await _publier_les_commandes()
    except Exception as erreur:
        LOG.warning("Bot Telegram non démarré : %s", erreur)
        try:
            await _application.shutdown()
        except Exception as second:  # noqa: BLE001 - on ferme au mieux
            LOG.debug("Fermeture de l'application Telegram : %s", second)
        _application = None
        _identite = None
        return False

    _identite = {"nom": moi.first_name, "identifiant": f"@{moi.username}",
                 "lien": f"https://t.me/{moi.username}"}
    LOG.info("Bot Telegram démarré : %s, %s", _identite["identifiant"], _identite["lien"])
    return True


async def demarrer_bot() -> None:
    """Démarre le bot, en réessayant tant qu'il n'y arrive pas.

    Un jeton absent est un cas normal : le bot ne démarre pas et l'API tourne
    quand même. Les tentatives sont espacées de plus en plus, jusqu'à cinq
    minutes : au démarrage du serveur, le DNS n'est pas toujours prêt.
    """
    global _reconnexion

    if not configuration().telegram_token:
        LOG.warning("Pas de jeton Telegram : le bot ne démarre pas, "
                    "les alertes restent en file.")
        return

    async def insister() -> None:
        attente = 5
        while not await _tenter_demarrage():
            await asyncio.sleep(attente)
            attente = min(attente * 2, 300)

    _reconnexion = asyncio.create_task(insister())


def identite() -> dict | None:
    """Nom du bot, pour savoir où le chercher dans Telegram."""
    return _identite


async def arreter_bot() -> None:
    global _application, _identite, _reconnexion

    if _reconnexion is not None:
        _reconnexion.cancel()
        _reconnexion = None

    if _application is None:
        return
    if _application.updater is not None:
        await _application.updater.stop()
    await _application.stop()
    await _application.shutdown()
    _application = None
    _identite = None
