"""Bot Telegram : recevoir les rappels, valider d'un bouton.

Ce module ne contient que du branchement. Ce que le bot sait faire vit dans
`conversation.py`, qui se teste sans parler à Telegram.

Le bot tourne dans le même processus que l'API : pour deux utilisateurs, un
conteneur de plus ne se justifie pas. Sans jeton, il ne démarre simplement pas
et l'API fonctionne normalement, les notifications restant en file.
"""

from __future__ import annotations

import asyncio
import logging

from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.constants import ParseMode
from telegram.ext import (
    Application,
    CallbackQueryHandler,
    CommandHandler,
    ContextTypes,
)

from api import conversation as conv
from api.config import configuration

LOG = logging.getLogger(__name__)

_application: Application | None = None
_identite: dict | None = None

AIDE = """Commandes :

/planning — ce qui est prévu aujourd'hui
/demain — ce qui est prévu demain
/retards — ce qui traîne
/stock — uniforme et prochaine lessive
/conflits — cours en double à départager
/absent JJ/MM JJ/MM lieu — je ne suis pas à l'appartement
/collecter — forcer une collecte
/lien CODE URL — donner l'URL d'un flux
/oublie — délier ce compte Telegram"""


async def _appelant(update: Update) -> dict | None:
    """Compte associé à cette conversation, ou None si non appairé."""
    if update.effective_user is None:
        return None
    return await asyncio.to_thread(conv.compte_de, update.effective_user.id)


async def _refuser(update: Update) -> None:
    await update.effective_message.reply_text(
        "Je ne te connais pas encore. Envoie « /demarrer TA_CLE_API » pour "
        "relier ce compte."
    )


# ---------------------------------------------------------------------------
# Commandes
# ---------------------------------------------------------------------------

async def demarrer(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    if not contexte.args:
        await update.effective_message.reply_text(
            "Envoie « /demarrer TA_CLE_API ». La clé est celle du fichier .env."
        )
        return

    compte = await asyncio.to_thread(conv.appairer, contexte.args[0],
                                     update.effective_user.id)
    if compte is None:
        # Message volontairement identique en cas de clé inconnue ou de compte
        # désactivé : inutile d'indiquer laquelle des deux hypothèses est la
        # bonne à quelqu'un qui essaie des clés au hasard.
        await update.effective_message.reply_text("Clé inconnue.")
        return

    await update.effective_message.reply_text(
        f"Bonjour {compte['pseudo']}. Je t'enverrai ton planning le matin et "
        f"les rappels le soir.\n\n{AIDE}"
    )


async def oublie(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    await asyncio.to_thread(conv.desappairer, update.effective_user.id)
    await update.effective_message.reply_text("C'est fait, je ne t'écrirai plus.")


async def aide(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    await update.effective_message.reply_text(AIDE)


async def planning(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    compte = await _appelant(update)
    if compte is None:
        return await _refuser(update)

    dans = 1 if (contexte.args and contexte.args[0] == "demain") else 0
    texte = await asyncio.to_thread(conv.planning_du_jour, compte["id_utilisateur"], dans)
    titre = "Demain" if dans else "Aujourd'hui"
    await update.effective_message.reply_text(f"{titre} :\n{texte}")


async def demain(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    contexte.args = ["demain"]
    await planning(update, contexte)


async def retards(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    compte = await _appelant(update)
    if compte is None:
        return await _refuser(update)

    taches = await asyncio.to_thread(conv.taches_en_retard, compte["id_utilisateur"])
    if not taches:
        await update.effective_message.reply_text("Rien en retard.")
        return

    for tache in taches:
        await update.effective_message.reply_text(
            f"{tache['tache_libelle']} — en retard de {tache['jours_de_retard']} j",
            reply_markup=_boutons(tache["id_occurrence"]),
        )


async def stock(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    compte = await _appelant(update)
    if compte is None:
        return await _refuser(update)

    texte = await asyncio.to_thread(conv.etat_du_stock, compte["id_utilisateur"])
    await update.effective_message.reply_text(texte)


async def conflits(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    compte = await _appelant(update)
    if compte is None:
        return await _refuser(update)

    en_attente = await asyncio.to_thread(conv.conflits_a_arbitrer)
    if not en_attente:
        await update.effective_message.reply_text("Aucun conflit à départager.")
        return

    for conflit in en_attente:
        await update.effective_message.reply_text(
            conv.decrire_conflit(conflit),
            reply_markup=InlineKeyboardMarkup([[
                InlineKeyboardButton(
                    "Le 1er", callback_data=f"conflit:existante:{conflit['id_conflit']}"),
                InlineKeyboardButton(
                    "Le 2e", callback_data=f"conflit:nouvelle:{conflit['id_conflit']}"),
            ]]),
        )


async def absent(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    """Déclarer qu'on ne sera pas dans l'appartement."""
    compte = await _appelant(update)
    if compte is None:
        return await _refuser(update)

    if not contexte.args:
        absences = await asyncio.to_thread(conv.absences_a_venir, compte["id_utilisateur"])
        if not absences:
            await update.effective_message.reply_text(
                "Aucune absence prévue.\n"
                "Pour en déclarer une : « /absent 22/08 24/08 Saint-Dié »."
            )
            return

        lignes = [
            f"• {conv._jour(a['debut'])} → {conv._jour(a['fin'])}"
            f"{' (' + a['lieu'] + ')' if a['lieu'] else ''}"
            f"{' — en cours' if a['en_cours'] else ''}"
            for a in absences
        ]
        await update.effective_message.reply_text("Absences prévues :\n" + "\n".join(lignes))
        return

    periode = conv.lire_periode(contexte.args)
    if periode is None:
        await update.effective_message.reply_text(
            "Je n'ai pas compris les dates. Format attendu : « /absent 22/08 24/08 »."
        )
        return

    debut, fin = periode
    lieu = " ".join(contexte.args[2:]) or None

    try:
        creee = await asyncio.to_thread(
            conv.declarer_absence, compte["id_utilisateur"], debut, fin, lieu)
    except Exception as erreur:
        await update.effective_message.reply_text(_message_lisible(erreur))
        return

    # Le planning se refait aussitôt : sans cela, les tâches resteraient posées
    # sur des jours où l'on ne sera pas là.
    from api.ordonnanceur import placer
    await asyncio.to_thread(placer)

    await update.effective_message.reply_text(
        f"Noté, absent du {conv._jour(creee['debut'])} au {conv._jour(creee['fin'])}"
        f"{' à ' + lieu if lieu else ''}. "
        f"Les tâches ménagères de ces jours-là sont replacées."
    )


async def collecter(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    compte = await _appelant(update)
    if compte is None:
        return await _refuser(update)

    from api.collecteurs.service import CollecteImpossible, collecter_source, sources_a_collecter

    codes = contexte.args or await asyncio.to_thread(sources_a_collecter)
    if not codes:
        await update.effective_message.reply_text("Rien à collecter pour l'instant.")
        return

    for code in codes:
        try:
            bilan = await asyncio.to_thread(collecter_source, code, compte["id_utilisateur"])
        except CollecteImpossible as erreur:
            await update.effective_message.reply_text(f"{code} : {erreur.message}")
            continue

        await update.effective_message.reply_text(
            f"{code} : {bilan['crees']} nouveau(x), {bilan['mis_a_jour']} mis à jour, "
            f"{bilan['annules']} annulé(s)."
        )


async def lien(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    """Donne l'URL d'un flux sans jamais l'écrire dans le dépôt."""
    compte = await _appelant(update)
    if compte is None:
        return await _refuser(update)

    if len(contexte.args) < 2:
        await update.effective_message.reply_text("Usage : /lien IDMC_ICS https://...")
        return

    code, url = contexte.args[0].upper(), contexte.args[1]
    from api.base import executer

    modifiee = await asyncio.to_thread(
        executer,
        "UPDATE source SET url = %(url)s WHERE code = %(code)s RETURNING code",
        {"code": code, "url": url},
    )
    if modifiee is None:
        await update.effective_message.reply_text(f"Source {code} inconnue.")
        return

    # On efface le message : il contient une URL avec un jeton d'accès.
    try:
        await update.effective_message.delete()
    except Exception:
        LOG.info("Message contenant l'URL non supprimé, droits insuffisants")

    await contexte.bot.send_message(
        update.effective_chat.id,
        f"URL de {code} enregistrée, et ton message effacé : il contenait un jeton.",
    )


# ---------------------------------------------------------------------------
# Boutons
# ---------------------------------------------------------------------------

def _boutons(id_occurrence: int) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([[
        InlineKeyboardButton("Fait", callback_data=f"tache:valider:{id_occurrence}"),
        InlineKeyboardButton("Plus tard", callback_data=f"tache:reporter:{id_occurrence}"),
        InlineKeyboardButton("Non", callback_data=f"tache:refuser:{id_occurrence}"),
    ]])


async def bouton(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    requete = update.callback_query
    await requete.answer()

    compte = await _appelant(update)
    if compte is None:
        await requete.edit_message_text("Compte non relié.")
        return

    genre, choix, identifiant = requete.data.split(":", 2)

    try:
        if genre == "tache":
            reponse = await asyncio.to_thread(
                conv.executer_action, choix, int(identifiant), compte["id_utilisateur"])
        else:
            reponse = await asyncio.to_thread(
                conv.trancher_conflit, int(identifiant), choix, compte["id_utilisateur"])
    except Exception as erreur:
        # Les refus de la base sont déjà rédigés en français : on les montre
        # tels quels plutôt que d'inventer un message générique.
        reponse = _message_lisible(erreur)

    await requete.edit_message_text(f"{requete.message.text}\n\n→ {reponse}")


def _message_lisible(erreur: Exception) -> str:
    diag = getattr(erreur, "diag", None)
    if diag is not None and diag.message_primary:
        return diag.message_primary
    LOG.exception("Action impossible")
    return "Impossible pour l'instant."


# ---------------------------------------------------------------------------
# Envoi de la file
# ---------------------------------------------------------------------------

async def vider_la_file(contexte: ContextTypes.DEFAULT_TYPE) -> None:
    if conv.en_silence():
        return

    for notification in await asyncio.to_thread(conv.notifications_a_envoyer):
        boutons = None
        # Seuls les rappels portent des boutons : un bilan du matin en aurait
        # autant qu'il y a de tâches, ce qui ne veut rien dire.
        if notification["type"] == "rappel" and notification["id_occurrence"]:
            boutons = _boutons(notification["id_occurrence"])

        try:
            await contexte.bot.send_message(
                notification["id_telegram"],
                notification["contenu"],
                reply_markup=boutons,
                parse_mode=ParseMode.HTML if "<" in notification["contenu"] else None,
            )
            await asyncio.to_thread(conv.marquer_envoyee, notification["id_notification"], True)
        except Exception:
            # R28 : un échec d'envoi laisse la notification en attente.
            LOG.exception("Envoi impossible, notification %s conservée",
                          notification["id_notification"])
            await asyncio.to_thread(conv.marquer_envoyee, notification["id_notification"], False)


# ---------------------------------------------------------------------------
# Cycle de vie
# ---------------------------------------------------------------------------

def construire() -> Application:
    application = Application.builder().token(configuration().telegram_token).build()

    application.add_handler(CommandHandler("start", demarrer))
    application.add_handler(CommandHandler("demarrer", demarrer))
    application.add_handler(CommandHandler("aide", aide))
    application.add_handler(CommandHandler("help", aide))
    application.add_handler(CommandHandler("planning", planning))
    application.add_handler(CommandHandler("demain", demain))
    application.add_handler(CommandHandler("retards", retards))
    application.add_handler(CommandHandler("stock", stock))
    application.add_handler(CommandHandler("conflits", conflits))
    application.add_handler(CommandHandler("absent", absent))
    application.add_handler(CommandHandler("collecter", collecter))
    application.add_handler(CommandHandler("lien", lien))
    application.add_handler(CommandHandler("oublie", oublie))
    application.add_handler(CallbackQueryHandler(bouton))

    if application.job_queue is not None:
        application.job_queue.run_repeating(vider_la_file, interval=60, first=15)

    return application


async def demarrer_bot() -> None:
    """Démarre le bot, ou explique pourquoi il ne démarre pas.

    Un jeton absent est un cas normal ; un jeton invalide est une erreur qu'il
    faut voir tout de suite, pas découvrir en attendant un message qui ne vient
    jamais. D'où l'appel à get_me au démarrage : il valide le jeton et donne le
    nom sous lequel chercher le bot dans Telegram.
    """
    global _application, _identite

    if not configuration().telegram_token:
        LOG.warning("Pas de jeton Telegram : le bot ne démarre pas, "
                    "les notifications restent en file.")
        return

    _application = construire()
    try:
        await _application.initialize()
        moi = await _application.bot.get_me()
        await _application.start()
        await _application.updater.start_polling(drop_pending_updates=True)
    except Exception as erreur:
        LOG.error("Bot Telegram non démarré : %s", erreur)
        _application = None
        _identite = None
        return

    _identite = {"nom": moi.first_name, "identifiant": f"@{moi.username}",
                 "lien": f"https://t.me/{moi.username}"}
    LOG.info("Bot Telegram démarré : %s — %s", _identite["identifiant"], _identite["lien"])


def identite() -> dict | None:
    """Nom du bot, pour savoir où le chercher dans Telegram."""
    return _identite


async def arreter_bot() -> None:
    global _application, _identite
    if _application is None:
        return
    if _application.updater is not None:
        await _application.updater.stop()
    await _application.stop()
    await _application.shutdown()
    _application = None
    _identite = None
