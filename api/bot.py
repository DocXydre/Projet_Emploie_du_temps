"""Bot Telegram : commandes, boutons, envoi des notifications.

Ce module ne contient que du branchement. Ce que le bot sait faire vit dans
`conversation.py`, qui se teste sans parler à Telegram.

Le bot tourne dans le processus de l'API. Sans jeton, il ne démarre pas et le
reste fonctionne, les notifications restant en file.
"""

from __future__ import annotations

import asyncio
import logging

from telegram import BotCommand, InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.constants import ParseMode
from telegram.ext import (
    Application,
    CallbackQueryHandler,
    CommandHandler,
    ContextTypes,
)

from api import billets, propositions, trajets
from api import conversation as conv
from api.collecteurs.courriel import BoiteIndisponible
from api.collecteurs.sncf import TrajetImpossible
from api.config import configuration

LOG = logging.getLogger(__name__)

_application: Application | None = None
_identite: dict | None = None
# Tâche de fond qui réessaie de joindre Telegram tant que le bot n'est pas en
# ligne. Gardée pour pouvoir l'annuler à l'arrêt de l'API.
_reconnexion: asyncio.Task | None = None

# L'aide se construit à partir du catalogue des commandes, en bas de ce
# fichier : le texte suivait mal les ajouts quand il était écrit à la main.


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
        f"les rappels le soir.\n\n{texte_aide()}",
        parse_mode=ParseMode.HTML,
    )


async def oublie(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    await asyncio.to_thread(conv.desappairer, update.effective_user.id)
    await update.effective_message.reply_text("C'est fait, je ne t'écrirai plus.")


async def aide(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    await update.effective_message.reply_text(texte_aide(),
                                              parse_mode=ParseMode.HTML)


MENU = [
    [("Valider une tâche", "valider"), ("Aujourd'hui", "jour")],
    [("En retard", "retards"), ("Demain", "demain")],
    [("C'est déjà fait", "fait"), ("Ajouter au planning", "ajouter")],
    [("Uniforme", "stock"), ("Corriger le stock", "recaler")],
    [("Sport", "sport"), ("Organiser le sport", "organiser")],
    [("Trains", "train"), ("Billets", "billets")],
    [("Je pars", "parti"), ("Je rentre", "retour")],
]


def _clavier_menu() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([
        [InlineKeyboardButton(libelle, callback_data=f"menu:{action}:0")
         for libelle, action in ligne]
        for ligne in MENU
    ])


async def menu(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    """Un point d'entrée unique, avec ce qui vient en tête.

    Retenir une douzaine de commandes est le meilleur moyen de n'en utiliser
    aucune. Le menu annonce d'abord la prochaine échéance — sans quoi il
    faudrait cliquer pour savoir s'il y a quelque chose à savoir.
    """
    compte = await _appelant(update)
    if compte is None:
        return await _refuser(update)

    suite = await asyncio.to_thread(conv.prochaine_chose, compte["id_utilisateur"])
    en_retard = await asyncio.to_thread(conv.taches_en_retard, compte["id_utilisateur"])

    texte = f"Prochain : {suite}"
    if en_retard:
        texte += f"\nEn retard : {len(en_retard)} tâche(s)"

    await update.effective_message.reply_text(texte, reply_markup=_clavier_menu())


async def valider(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    """Ce qu'on peut cocher maintenant, sans attendre la relance du soir.

    On fait la vaisselle quand on la fait, pas à 21h.
    """
    compte = await _appelant(update)
    if compte is None:
        return await _refuser(update)

    a_faire = await asyncio.to_thread(conv.a_valider, compte["id_utilisateur"])
    if not a_faire:
        await update.effective_message.reply_text(
            "Rien à cocher aujourd'hui. « /menu » pour le reste.")
        return

    for tache in a_faire:
        retard = (f" — en retard de {tache['jours_de_retard']} j"
                  if tache["en_retard"] else "")
        await update.effective_message.reply_text(
            f"{tache['tache_libelle']}{retard}",
            reply_markup=_boutons(tache["id_occurrence"]))


async def fait(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    """« J'ai passé l'aspirateur », alors qu'il n'était pas demandé.

    /valider ne montre que ce qui est prévu aujourd'hui. Une tâche faite en
    avance n'y figure pas, et il n'y avait aucun moyen de la déclarer : elle
    revenait le lendemain comme si de rien n'était.
    """
    compte = await _appelant(update)
    if compte is None:
        return await _refuser(update)

    if contexte.args:
        reponse = await asyncio.to_thread(
            conv.declarer_faite, compte["id_utilisateur"], " ".join(contexte.args))
        await update.effective_message.reply_text(reponse)
        return

    taches = await asyncio.to_thread(conv.taches_declarables, compte["id_utilisateur"])
    if not taches:
        await update.effective_message.reply_text("Aucune tâche à déclarer.")
        return

    boutons = [[InlineKeyboardButton(t["libelle"], callback_data=f"fait:{t['code']}:0")]
               for t in taches]
    await update.effective_message.reply_text(
        "Qu'est-ce qui est fait ?",
        reply_markup=InlineKeyboardMarkup(boutons))


async def ajouter(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    """Poser un créneau au planning : « /ajouter Médecin 12/09 14h 16h ».

    Le jour peut être omis pour aujourd'hui. Le libellé est tout ce qui n'est
    ni une date ni une heure, ce qui évite d'avoir à mettre des guillemets sur
    un téléphone.
    """
    compte = await _appelant(update)
    if compte is None:
        return await _refuser(update)

    lu = conv.lire_creneau(contexte.args or [])
    if lu is None:
        await update.effective_message.reply_text(
            "Format : /ajouter Titre JJ/MM 14h 16h\n\n"
            "Par exemple :\n"
            "/ajouter Rendez-vous médecin 12/09 14h 16h\n"
            "/ajouter Révisions 18h 20h30   (aujourd'hui)")
        return

    libelle, debut, fin = lu
    try:
        await asyncio.to_thread(conv.ajouter_occupation,
                                compte["id_utilisateur"], libelle, debut, fin)
    except Exception as erreur:
        await update.effective_message.reply_text(_message_lisible(erreur))
        return

    await update.effective_message.reply_text(
        f"C'est posé : {libelle}\n"
        f"{conv._jour(debut)} de {conv._heure(debut)} à {conv._heure(fin)}\n\n"
        f"Les tâches qui tombaient là ont été déplacées.")


async def recaler(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    """« J'ai deux t-shirts propres. »

    Le comptage suit les services et les lessives validées ; la réalité, elle,
    avance sans lui. Un article par message, avec un bouton par quantité
    possible — c'est plus court que de taper, et on ne peut pas se tromper de
    format.
    """
    compte = await _appelant(update)
    if compte is None:
        return await _refuser(update)

    if len(contexte.args or []) == 2 and contexte.args[1].isdigit():
        code, quantite = contexte.args[0].upper(), int(contexte.args[1])
        await _appliquer_recalage(update.effective_message, code, quantite)
        return

    articles = await asyncio.to_thread(conv.articles_stock)
    for article in articles:
        boutons = [InlineKeyboardButton(str(n), callback_data=f"recal:{article['code']}:{n}")
                   for n in range(article["quantite_totale"] + 1)]
        await update.effective_message.reply_text(
            f"{article['libelle']} — {article['quantite_propre']} propre(s) selon moi.\n"
            f"Combien en as-tu vraiment ?",
            reply_markup=InlineKeyboardMarkup([boutons]))


async def _appliquer_recalage(message, code: str, quantite: int) -> None:
    try:
        resultat = await asyncio.to_thread(conv.recaler_stock, code, quantite)
    except Exception as erreur:
        await message.reply_text(_message_lisible(erreur))
        return

    if resultat is None:
        await message.reply_text(f"Article {code} inconnu.")
        return

    ecart = resultat["ecart"]
    if ecart == 0:
        suite = "j'avais déjà le bon compte."
    else:
        suite = f"j'en comptais {ecart:+d} de moins que toi." if ecart > 0 \
                else f"j'en comptais {-ecart} de trop."
    await message.reply_text(
        f"Noté : {resultat['quantite_propre']} propre(s) — {suite}")


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

    # On refait le planning tout de suite, pour déplacer les tâches posées
    # sur des jours d'absence.
    from api.ordonnanceur import placer
    await asyncio.to_thread(placer)

    await update.effective_message.reply_text(
        f"Noté, absent du {conv._jour(creee['debut'])} au {conv._jour(creee['fin'])}"
        f"{' à ' + lieu if lieu else ''}. "
        f"Les tâches ménagères de ces jours-là sont replacées."
    )


async def calendrier(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    """Envoie l'adresse d'abonnement, là où on en a besoin : sur le téléphone.

    C'est tout l'intérêt de passer par le bot : l'adresse contient un jeton de
    trente-deux caractères que personne ne recopie à la main sans se tromper.
    Elle est envoyée en monospace et non en lien, parce qu'un lien touché sur
    iOS importe les événements au lieu de créer un abonnement.
    """
    compte = await _appelant(update)
    if compte is None:
        return await _refuser(update)

    renouveler = bool(contexte.args and contexte.args[0] in ("renouveler", "reset"))
    if renouveler:
        await asyncio.to_thread(conv.renouveler_calendrier, compte["id_utilisateur"])

    lien = await asyncio.to_thread(conv.url_calendrier, compte["id_utilisateur"])
    if lien is None:
        await update.effective_message.reply_text(
            "Je ne sais pas sous quel nom cette machine est joignable depuis "
            "ton téléphone. Renseigne HOTE_PUBLIC dans le .env — par exemple "
            "« HOTE_PUBLIC=mon-mac.local:8000 » — puis relance l'API."
        )
        return

    entete = ("Nouveau lien. L'ancien ne fonctionne plus, il faut te réabonner.\n\n"
              if renouveler else "")

    # Le chemin par les réglages est le chemin normal, pas le recours. Toucher
    # un lien vers un .ics importe les événements une fois pour toutes au lieu
    # de créer un abonnement : le calendrier ne se met alors plus jamais à jour,
    # et rien ne le signale. L'adresse part donc en <code>, que Telegram affiche
    # sans en faire un lien et qu'un appui long recopie.
    corps = (
        f"{entete}"
        f"Copie cette adresse :\n\n"
        f"<code>{lien['url']}</code>\n\n"
        f"puis, sur le téléphone :\n"
        f"Réglages → Apps → Calendrier → Comptes → Ajouter un compte → "
        f"Autre → Ajouter un calendrier avec abonnement.\n"
        f"Colle l'adresse telle quelle et règle l'actualisation sur "
        f"« Toutes les heures ».\n\n"
    )

    # Sur un flux en clair seulement : ailleurs, iOS traduirait webcal:// en
    # http:// et l'abonnement échouerait.
    if lien["webcal"]:
        corps += (f"Sur un ordinateur, ce lien ouvre directement la boîte "
                  f"d'abonnement :\n{lien['webcal']}\n\n")

    corps += ("Le lien ne donne que la lecture du planning. Pour le révoquer : "
              "« /calendrier renouveler ».")

    await update.effective_message.reply_text(corps, parse_mode=ParseMode.HTML)


async def train(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    """Propose d'aller à Saint-Dié quand l'emploi du temps le permet.

    On ne demande pas les dates : le système les connaît mieux que la mémoire.
    Il cherche les creux d'au moins deux jours, et ne propose que des trains
    qu'on puisse effectivement attraper après le dernier cours ou service.
    """
    compte = await _appelant(update)
    if compte is None:
        return await _refuser(update)

    creneaux = await asyncio.to_thread(trajets.fenetres, compte["id_utilisateur"])
    if not creneaux:
        conf = configuration()
        await update.effective_message.reply_text(
            f"Aucun creux de {conf.fenetre_absence_heures} h dans les "
            f"{conf.horizon_trajets_jours} jours qui viennent. "
            f"Soit l'emploi du temps est serré, soit les collectes n'ont pas "
            f"encore ramené la suite du semestre."
        )
        return

    if len(creneaux) == 1:
        await _proposer_aller(update, contexte, compte, rang=1)
        return

    lignes = [f"{rang}. {trajets.resumer_fenetre(c)}"
              for rang, c in enumerate(creneaux[:4], start=1)]
    await update.effective_message.reply_text(
        "Fenêtres assez longues pour un aller-retour :\n\n" + "\n".join(lignes),
        reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton(f"Fenêtre {rang}", callback_data=f"train:fenetre:{rang}")]
            for rang in range(1, min(len(creneaux), 4) + 1)
        ]),
    )


def _heures(trajet: dict) -> str:
    return f"{conv._heure(trajet['depart'])} → {conv._heure(trajet['arrivee'])}"


async def _proposer_aller(update: Update, contexte: ContextTypes.DEFAULT_TYPE,
                          compte: dict, rang: int) -> None:
    message = update.effective_message
    try:
        resultat = await asyncio.to_thread(
            trajets.proposer_aller, compte["id_utilisateur"], rang)
    except TrajetImpossible as erreur:
        await message.reply_text(erreur.message)
        return

    creneau = resultat["fenetre"]
    if creneau is None:
        await message.reply_text("Cette fenêtre n'existe plus. Refais /train.")
        return

    if not resultat["trajets"]:
        await message.reply_text(
            f"{trajets.resumer_fenetre(creneau)}\n\n"
            f"Aucun train après {conv._heure(creneau['depart_au_plus_tot'])} "
            f"ce jour-là."
        )
        return

    entete = trajets.resumer_fenetre(creneau)
    if creneau["fin_obligation_avant"] is not None:
        entete += (f"\n\nTu finis à {conv._heure(creneau['fin_obligation_avant'])} : "
                   f"premier train attrapable après "
                   f"{conv._heure(creneau['depart_au_plus_tot'])}.")

    await message.reply_text(
        entete + "\n\nAller :",
        reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton(f"{_heures(t)} · {t['resume']}",
                                  callback_data=f"train:aller:{t['id_trajet']}")]
            for t in resultat["trajets"]
        ]),
    )


async def _proposer_retour(contexte: ContextTypes.DEFAULT_TYPE, chat_id: int,
                           id_aller: int) -> None:
    try:
        resultat = await asyncio.to_thread(trajets.proposer_retour, id_aller)
    except TrajetImpossible as erreur:
        await contexte.bot.send_message(chat_id, erreur.message)
        return

    boutons = [
        [InlineKeyboardButton(f"{_heures(t)} · {t['resume']}",
                              callback_data=f"train:retour:{t['id_trajet']}")]
        for t in resultat["trajets"]
    ]
    # On peut enregistrer un aller sans retour : le retour se fixe plus tard.
    boutons.append([InlineKeyboardButton("Retour à fixer plus tard",
                                         callback_data=f"train:seul:{id_aller}")])

    entete = "Retour, du premier départ possible :"
    if not resultat["trajets"]:
        entete = ("Aucun retour ne rentre dans la fenêtre. "
                  "Tu peux quand même bloquer l'aller.")
    elif resultat["retour_au_plus_tard"] is not None:
        # L'ordre est annoncé parce qu'il n'est pas celui qu'on attend d'une
        # liste d'horaires : le premier bouton est le dernier train.
        entete = (f"Retour — rentré avant "
                  f"{conv._heure(resultat['retour_au_plus_tard'])}. "
                  f"Du dernier train aux plus tôt :")

    await contexte.bot.send_message(chat_id, entete, reply_markup=InlineKeyboardMarkup(boutons))


async def _confirmer_trajet(id_aller: int, id_retour: int | None) -> str:
    resultat = await asyncio.to_thread(trajets.retenir, id_aller, id_retour)
    absence = resultat["absence"]

    fin = ("retour à fixer" if id_retour is None
           else f"rentré le {conv._jour(absence['fin'])}")
    return (f"C'est noté : parti le {conv._jour(absence['debut'])}, {fin}.\n"
            f"Les tâches ménagères de ces jours-là sont replacées "
            f"({resultat['occurrences_replacees']} occurrence(s) repositionnée(s)).\n\n"
            f"Le billet, lui, reste à acheter.")


async def commande_billets(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    """Relève la boîte, puis liste les voyages qui en sont issus.

    Chaque absence née d'un courriel porte un bouton pour l'annuler. C'est la
    contrepartie de l'automatisme : le lecteur peut se tromper, et se tromper
    en silence gèlerait deux jours de ménage sans que personne ne comprenne.
    """
    compte = await _appelant(update)
    if compte is None:
        return await _refuser(update)

    try:
        bilan = await asyncio.to_thread(billets.relever, compte["id_utilisateur"])
    except BoiteIndisponible as erreur:
        await update.effective_message.reply_text(erreur.message)
        return

    await update.effective_message.reply_text(billets.resume(bilan))

    for revoir in await asyncio.to_thread(billets.a_revoir, 5):
        await update.effective_message.reply_text(
            f"Non exploité — {revoir['sujet'] or 'sans sujet'}\n{revoir['motif']}")

    voyages = await asyncio.to_thread(billets.absences_issues_de_billets)
    for voyage in voyages:
        reference = f" ({voyage['reference']})" if voyage["reference"] else ""
        await update.effective_message.reply_text(
            f"Billet{reference} : absent du {conv._jour(voyage['debut'])} "
            f"au {conv._jour(voyage['fin'])}"
            f"{' à ' + voyage['lieu'] if voyage['lieu'] else ''}",
            reply_markup=InlineKeyboardMarkup([[
                InlineKeyboardButton(
                    "Ce n'est pas ça, annule",
                    callback_data=f"billet:annuler:{voyage['id_absence']}"),
            ]]),
        )

    if not voyages and bilan["traites"] == 0:
        await update.effective_message.reply_text(
            "Aucun voyage déclaré par courriel pour l'instant.")


async def parti(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    """« Je pars maintenant. » Le cas qu'aucune déduction ne couvre."""
    compte = await _appelant(update)
    if compte is None:
        return await _refuser(update)

    lieu = " ".join(contexte.args) or None
    try:
        creee = await asyncio.to_thread(conv.partir, compte["id_utilisateur"], lieu)
    except Exception as erreur:
        await update.effective_message.reply_text(_message_lisible(erreur))
        return

    from api.ordonnanceur import placer
    replacees = await asyncio.to_thread(placer)

    await update.effective_message.reply_text(
        f"Bonne route{' à ' + lieu if lieu else ''}. Rien à faire jusqu'au "
        f"{conv._jour(creee['fin'])} ({replacees} occurrence(s) replacée(s)).\n"
        f"Envoie « /retour » en rentrant, même plus tôt que prévu."
    )


async def retour(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    """« Je suis rentré. » Y compris en voiture, y compris en avance.

    Sert à corriger les cas que le reste ne voit pas : billet mal lu, trajet
    annulé, retour improvisé en voiture. Termine l'absence à l'instant présent
    et relance le placement.
    """
    compte = await _appelant(update)
    if compte is None:
        return await _refuser(update)

    ferme = await asyncio.to_thread(conv.rentrer, compte["id_utilisateur"])
    if ferme is None:
        await update.effective_message.reply_text(
            "Tu n'es pas noté absent en ce moment — rien à fermer.")
        return

    from api.ordonnanceur import placer
    replacees = await asyncio.to_thread(placer)

    await update.effective_message.reply_text(
        f"Content de te revoir. Absence close, "
        f"{replacees} occurrence(s) replacée(s).\n"
        f"Tu retrouveras tes tâches dès demain — aujourd'hui n'est plus une "
        f"journée entièrement absente."
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


async def groupe(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    """Changer de groupe de TD : « /groupe 2 ».

    Le groupe est une donnée de configuration, en base et non dans le code. Le
    changer relance une collecte, qui retire les cours de l'ancien groupe encore
    à venir et pose ceux du nouveau.
    """
    compte = await _appelant(update)
    if compte is None:
        return await _refuser(update)

    if not contexte.args or not contexte.args[0].isdigit():
        actuel = await asyncio.to_thread(conv.groupe_actuel)
        await update.effective_message.reply_text(
            f"Groupe suivi : {actuel or 'aucun filtre'}\n\nPour en changer : /groupe 2")
        return

    voulu = int(contexte.args[0])
    await update.effective_message.reply_text(
        f"Passage au groupe {voulu}, je recollecte l'emploi du temps…")

    try:
        bilan = await asyncio.to_thread(conv.changer_groupe, voulu)
    except Exception as erreur:
        await update.effective_message.reply_text(_message_lisible(erreur))
        return

    if bilan is None:
        await update.effective_message.reply_text("Source IDMC_ICS inconnue.")
        return

    await update.effective_message.reply_text(
        f"Groupe {voulu}.\n"
        f"{bilan['crees']} cours ajouté(s), {bilan['annules']} retiré(s), "
        f"{bilan['mis_a_jour']} mis à jour.\n"
        f"{bilan['occurrences_replacees']} tâche(s) replacée(s).")


async def ecarter(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    """Les UE au choix qu'on ne suit pas : « /ecarter Traitement automatique des images ».

    L'ADE publie toutes les options dans le même flux. Sans argument, la
    commande liste ce qui est écarté, avec un bouton pour reprendre un cours.
    """
    compte = await _appelant(update)
    if compte is None:
        return await _refuser(update)

    if not contexte.args:
        liste = await asyncio.to_thread(conv.cours_ecartes)
        if not liste:
            await update.effective_message.reply_text(
                "Aucun cours écarté.\n\n"
                "Pour en écarter un :\n"
                "/ecarter Traitement automatique des images\n\n"
                "Un extrait du libellé suffit, les accents n'ont pas d'importance.")
            return

        # Le bouton porte le rang et non le libellé : Telegram limite les
        # données de rappel à 64 octets, et un nom de cours contenant « : »
        # casserait le découpage.
        boutons = [[InlineKeyboardButton(f"Reprendre {c}", callback_data=f"ecart:{rang}:0")]
                   for rang, c in enumerate(liste)]
        await update.effective_message.reply_text(
            "Cours écartés :\n" + "\n".join(f"• {c}" for c in liste),
            reply_markup=InlineKeyboardMarkup(boutons))
        return

    libelle = " ".join(contexte.args)
    await update.effective_message.reply_text(f"J'écarte « {libelle} » et je recollecte…")
    await _appliquer_ecart(update.effective_message, conv.ecarter_cours, libelle)


async def _appliquer_ecart(message, action, libelle: str) -> None:
    try:
        bilan = await asyncio.to_thread(action, libelle)
    except Exception as erreur:
        await message.reply_text(_message_lisible(erreur))
        return

    if bilan is None:
        await message.reply_text("Source IDMC_ICS inconnue.")
        return

    restants = bilan["cours_ecartes"]
    await message.reply_text(
        f"{bilan['crees']} cours ajouté(s), {bilan['annules']} retiré(s).\n"
        f"{bilan['occurrences_replacees']} tâche(s) replacée(s).\n\n"
        + ("Écartés : " + ", ".join(restants) if restants else "Plus aucun cours écarté."))


async def lien(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    """Donne l'URL d'un flux sans jamais l'écrire dans le dépôt."""
    compte = await _appelant(update)
    if compte is None:
        return await _refuser(update)

    if len(contexte.args) < 2:
        await update.effective_message.reply_text("Usage : /lien IDMC_ICS https://...")
        return

    code, url = contexte.args[0].upper(), conv.url_collectable(contexte.args[1])
    from api.base import executer

    # Donner l'URL vaut demande de collecte : une source qu'on renseigne pour
    # la laisser éteinte n'existe pas. Les calendriers personnels naissent
    # inactifs faute d'adresse, et s'allument ici (COL-14).
    modifiee = await asyncio.to_thread(
        executer,
        "UPDATE source SET url = %(url)s, active = TRUE, etat = 'ok' "
        " WHERE code = %(code)s RETURNING code",
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


def _boutons_proposition(id_proposition: int) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([[
        InlineKeyboardButton("Voir les trains",
                             callback_data=f"prop:trains:{id_proposition}"),
        InlineKeyboardButton("Non merci",
                             callback_data=f"prop:non:{id_proposition}"),
    ]])


async def bouton(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    requete = update.callback_query
    await requete.answer()

    compte = await _appelant(update)
    if compte is None:
        await requete.edit_message_text("Compte non relié.")
        return

    genre, choix, identifiant = requete.data.split(":", 2)

    # Les trajets se déroulent en plusieurs temps : choisir un aller appelle la
    # question du retour. On acquitte donc le message courant, puis on pose la
    # suite dans un nouveau message.
    if genre == "train":
        await _bouton_train(update, contexte, compte, choix, identifiant)
        return

    if genre == "menu":
        # Le menu reste affiché après l'action, pour enchaîner sans retaper
        # /menu.
        await _bouton_menu(update, contexte, compte, choix)
        return

    if genre == "prop":
        await _bouton_proposition(update, contexte, compte, choix, int(identifiant))
        return

    if genre == "seance":
        await _bouton_seance(update, compte, choix, int(identifiant))
        return

    if genre == "ecart":
        liste = await asyncio.to_thread(conv.cours_ecartes)
        rang = int(choix)
        if rang >= len(liste):
            await requete.edit_message_text("Cette liste a changé depuis. Refais /ecarter.")
            return
        await _appliquer_ecart(requete.message, conv.reprendre_cours, liste[rang])
        return

    if genre == "recal":
        await _appliquer_recalage(requete.message, choix, int(identifiant))
        return

    if genre == "fait":
        reponse = await asyncio.to_thread(
            conv.declarer_faite, compte["id_utilisateur"], choix)
        await requete.edit_message_text(f"{requete.message.text}\n\n→ {reponse}")
        return

    if genre == "billet":
        try:
            replacees = await asyncio.to_thread(trajets.oublier, int(identifiant))
            reponse = (f"Annulé, les tâches reviennent "
                       f"({replacees} occurrence(s) replacée(s)).")
        except Exception as erreur:
            reponse = _message_lisible(erreur)
        await requete.edit_message_text(f"{requete.message.text}\n\n→ {reponse}")
        return

    try:
        if genre == "tache":
            reponse = await asyncio.to_thread(
                conv.executer_action, choix, int(identifiant), compte["id_utilisateur"])
        else:
            reponse = await asyncio.to_thread(
                conv.trancher_conflit, int(identifiant), choix, compte["id_utilisateur"])
    except Exception as erreur:
        # Les messages d'erreur de la base sont déjà en français : on les
        # affiche tels quels.
        reponse = _message_lisible(erreur)

    await requete.edit_message_text(f"{requete.message.text}\n\n→ {reponse}")


async def _bouton_train(update: Update, contexte: ContextTypes.DEFAULT_TYPE,
                        compte: dict, choix: str, identifiant: str) -> None:
    requete = update.callback_query
    chat = update.effective_chat.id

    if choix == "fenetre":
        await requete.edit_message_reply_markup(reply_markup=None)
        await _proposer_aller(update, contexte, compte, rang=int(identifiant))
        return

    if choix == "aller":
        await requete.edit_message_text(f"{requete.message.text}\n\n→ aller retenu")
        await _proposer_retour(contexte, chat, int(identifiant))
        return

    try:
        if choix == "retour":
            aller = await asyncio.to_thread(_aller_du_retour, int(identifiant))
            reponse = await _confirmer_trajet(aller, int(identifiant))
        elif choix == "seul":
            reponse = await _confirmer_trajet(int(identifiant), None)
        else:
            raise ValueError(f"Choix inconnu : {choix}")
    except Exception as erreur:
        reponse = _message_lisible(erreur)

    await requete.edit_message_text(f"{requete.message.text}\n\n→ {reponse}")


async def _bouton_menu(update: Update, contexte: ContextTypes.DEFAULT_TYPE,
                       compte: dict, choix: str) -> None:
    """Chaque bouton du menu rejoue la commande correspondante.

    Aucune logique propre : le menu est une façade. Deux chemins pour la même
    action finiraient par se contredire, et c'est toujours celui qu'on ne teste
    pas qui reste en arrière.
    """
    commandes = {
        "valider": valider,
        "fait": fait,
        "ajouter": ajouter,
        "jour": planning,
        "demain": demain,
        "retards": retards,
        "stock": stock,
        "recaler": recaler,
        "sport": seances_a_venir,
        "organiser": organiser,
        "parti": parti,
        "retour": retour,
        "train": train,
        "billets": commande_billets,
    }

    action = commandes.get(choix)
    if action is None:
        return

    contexte.args = []
    await action(update, contexte)


async def seances_a_venir(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    """Les prochaines séances de sport, avec leur lieu."""
    compte = await _appelant(update)
    if compte is None:
        return await _refuser(update)

    prochaines = await asyncio.to_thread(conv.seances_sport, compte["id_utilisateur"])
    if not prochaines:
        await update.effective_message.reply_text(
            "Aucune séance placée. Les creux sont peut-être trop courts.")
        return

    lignes = [
        f"• {conv._jour(s['debut'])} {conv._heure(s['debut'])}"
        f"–{conv._heure(s['fin'])} — {s['lieu'] or 'lieu à confirmer'}"
        for s in prochaines
    ]
    await update.effective_message.reply_text(
        "Séances à venir (trajet compris) :\n" + "\n".join(lignes))


# Un clavier de soixante boutons ne se lit pas. Au-delà, le message le dit et
# renvoie vers un second « /organiser ».
_MAX_BOUTONS = 24


def _boutons_sport(creneaux: list[dict]) -> InlineKeyboardMarkup | None:
    """Un bouton par jour et par lieu possible.

    Les données de rappel portent le jour en ISO et l'identifiant du lieu :
    c'est court, et ça reste juste même si la liste a changé entre l'envoi du
    message et le clic.
    """
    if not creneaux:
        return None

    JOURS = ("lun", "mar", "mer", "jeu", "ven", "sam", "dim")
    lignes = []
    for creneau in creneaux[:_MAX_BOUTONS]:
        jour = creneau["jour"]
        lignes.append([InlineKeyboardButton(
            f"{JOURS[jour.weekday()]} {jour.day:02d} · {creneau['libelle']} "
            f"{conv._heure(creneau['debut'])}",
            callback_data=f"seance:{jour.isoformat()}:{creneau['id_lieu']}")])
    return InlineKeyboardMarkup(lignes)


async def organiser(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    """Choisir ses séances de la semaine : quel jour, quel sport.

    C'est la proposition du lundi, rejouable à la demande — un emploi du temps
    change, et le choix de lundi matin n'engage pas jusqu'au dimanche.
    """
    compte = await _appelant(update)
    if compte is None:
        return await _refuser(update)

    from api import sport

    texte = await asyncio.to_thread(sport.resumer, compte["id_utilisateur"])
    if texte is None:
        await update.effective_message.reply_text(
            "Les séances de la semaine sont déjà toutes posées. « /sport » pour les voir.")
        return

    creneaux = await asyncio.to_thread(sport.possibilites, compte["id_utilisateur"])

    # Les boutons sont plafonnés : au-delà, la liste devient illisible. Le texte,
    # lui, montre tout, et choisir une séance raccourcit le reste.
    if len(creneaux) > _MAX_BOUTONS:
        texte += (f"\n\nBoutons limités aux {_MAX_BOUTONS} premiers créneaux. "
                  f"Relance « /organiser » après avoir choisi pour voir la suite.")

    await update.effective_message.reply_text(
        texte, reply_markup=_boutons_sport(creneaux), parse_mode=ParseMode.HTML)


async def _bouton_seance(update: Update, compte: dict, jour: str, id_lieu: int) -> None:
    from datetime import date as _date

    from api import sport

    requete = update.callback_query
    try:
        retenue = await asyncio.to_thread(
            sport.retenir, compte["id_utilisateur"], _date.fromisoformat(jour), id_lieu)
    except Exception as erreur:
        await requete.message.reply_text(_message_lisible(erreur))
        return

    if retenue is None:
        await requete.message.reply_text("Séance introuvable.")
        return

    await requete.message.reply_text(
        f"C'est noté : {retenue['lieu']} le {conv._jour(retenue['debut'])} "
        f"à {conv._heure(retenue['debut'])}.")

    # On repropose ce qui reste, la liste ayant changé : le jour retenu n'est
    # plus disponible, et une séance de moins est à caser.
    texte = await asyncio.to_thread(sport.resumer, compte["id_utilisateur"])
    if texte is None:
        await requete.message.reply_text("Toutes les séances de la semaine sont posées.")
        return

    creneaux = await asyncio.to_thread(sport.possibilites, compte["id_utilisateur"])
    await requete.message.reply_text(texte, reply_markup=_boutons_sport(creneaux))


async def piscine(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    """Les créneaux connus de la piscine, et leur fraîcheur.

    Avec un argument quelconque, force un relevé sur la page du SUAPS au lieu
    d'attendre celui de 6h50.
    """
    compte = await _appelant(update)
    if compte is None:
        return await _refuser(update)

    from api import sport

    if contexte.args:
        await update.effective_message.reply_text("Je relis la page du SUAPS…")
        bilans = await asyncio.to_thread(sport.rafraichir_horaires)
        for bilan in bilans:
            detail = bilan.get("detail") or f"{bilan.get('creneaux', 0)} créneau(x)"
            rejets = bilan.get("rejets") or {}
            texte = f"{bilan['lieu']} — {bilan['etat']} : {detail}"
            if rejets:
                texte += "\n" + "\n".join(f"  écarté : {m} ×{n}" for m, n in rejets.items())
            await update.effective_message.reply_text(texte)

    creneaux = await asyncio.to_thread(sport.horaires)
    if not creneaux:
        await update.effective_message.reply_text("Aucun créneau connu.")
        return

    JOURS = ("lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche")
    par_jour: dict[int, list[str]] = {}
    for creneau in creneaux:
        par_jour.setdefault(creneau["jour_semaine"], []).append(
            f"{creneau['heure_debut']:%H:%M}–{creneau['heure_fin']:%H:%M}")

    lignes = [f"{JOURS[j - 1]} : {' · '.join(h)}" for j, h in sorted(par_jour.items())]
    releve = creneaux[0]["horaires_releves_le"]
    lignes.append("")
    lignes.append(f"Relevé le {conv._jour(releve)} à {conv._heure(releve)}"
                  if releve else "Jamais relevé automatiquement.")

    await update.effective_message.reply_text("\n".join(lignes))


async def _bouton_proposition(update: Update, contexte: ContextTypes.DEFAULT_TYPE,
                              compte: dict, choix: str, id_proposition: int) -> None:
    """Répondre à une proposition : regarder les trains, ou décliner."""
    requete = update.callback_query

    if choix == "non":
        await asyncio.to_thread(propositions.ecarter, id_proposition)
        # WKD-4 : on ne revient pas à la charge sur un week-end décliné.
        await requete.edit_message_text(
            f"{requete.message.text}\n\n→ Noté, je n'en reparle plus.")
        return

    proposition = await asyncio.to_thread(propositions.detail, id_proposition)
    if proposition is None:
        await requete.edit_message_text(
            f"{requete.message.text}\n\n→ Cette proposition n'existe plus.")
        return

    rang = await asyncio.to_thread(
        trajets.rang_contenant, compte["id_utilisateur"], proposition["debut"])
    if rang is None:
        # L'emploi du temps a changé depuis l'annonce : un cours est tombé au
        # milieu, la fenêtre n'existe plus.
        await requete.edit_message_text(
            f"{requete.message.text}\n\n→ Ce creux a disparu de l'emploi du temps.")
        return

    await requete.edit_message_reply_markup(reply_markup=None)
    await _proposer_aller(update, contexte, compte, rang)


def _aller_du_retour(id_retour: int) -> int:
    from api.base import un_seul

    ligne = un_seul("SELECT id_trajet_aller FROM trajet WHERE id_trajet = %(id)s",
                    {"id": id_retour})
    if ligne is None or ligne["id_trajet_aller"] is None:
        raise ValueError("Ce retour n'est rattaché à aucun aller")
    return ligne["id_trajet_aller"]


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
        # Seuls les rappels, qui portent sur une occurrence précise, ont des
        # boutons de validation.
        if notification["type"] == "rappel" and notification["id_occurrence"]:
            boutons = _boutons(notification["id_occurrence"])
        elif notification["type"] == "sport":
            # Les créneaux sont recalculés au moment de l'envoi, et non à la
            # rédaction : entre les deux, un cours a pu tomber.
            from api import sport
            creneaux = await asyncio.to_thread(
                sport.possibilites, notification["id_utilisateur"])
            boutons = _boutons_sport(creneaux)
        elif notification.get("id_proposition"):
            # Boutons « oui / non merci » sous une proposition de week-end.
            boutons = _boutons_proposition(notification["id_proposition"])

        try:
            await contexte.bot.send_message(
                notification["id_telegram"],
                notification["contenu"],
                reply_markup=boutons,
                parse_mode=ParseMode.HTML if "<" in notification["contenu"] else None,
            )
            await asyncio.to_thread(conv.marquer_envoyee, notification["id_notification"], True)
        except Exception:
            # NOT-2 : un échec d'envoi laisse la notification en attente.
            LOG.exception("Envoi impossible, notification %s conservée",
                          notification["id_notification"])
            await asyncio.to_thread(conv.marquer_envoyee, notification["id_notification"], False)


# ---------------------------------------------------------------------------
# Cycle de vie
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Catalogue des commandes
#
# Une seule liste pour trois usages : l'enregistrement des handlers, le texte
# de /aide, et le menu que Telegram propose quand on tape « / ». Écrire une
# commande à trois endroits, c'est s'assurer qu'un jour elle n'existera qu'à
# deux : l'aide écrite à la main avait déjà oublié /demarrer et /aide.
# ---------------------------------------------------------------------------

def catalogue() -> list[tuple[str, str, str, str, object]]:
    """Groupe, nom, argument, description, fonction. Dans l'ordre d'affichage."""
    return [
        ("Au quotidien", "menu", "", "tout, en boutons", menu),
        ("Au quotidien", "planning", "", "ce qui est prévu aujourd'hui", planning),
        ("Au quotidien", "demain", "", "ce qui est prévu demain", demain),
        ("Au quotidien", "valider", "", "cocher ce qui est fait", valider),
        ("Au quotidien", "fait", "", "c'est fait, même si ce n'était pas prévu", fait),
        ("Au quotidien", "retards", "", "ce qui traîne", retards),
        ("Au quotidien", "ajouter", "Titre JJ/MM 14h 16h",
         "poser un créneau au planning", ajouter),

        ("Sport", "sport", "", "les prochaines séances", seances_a_venir),
        ("Sport", "organiser", "", "choisir ses séances de la semaine", organiser),
        ("Sport", "piscine", "maj", "les créneaux du SUAPS", piscine),

        ("Maison", "stock", "", "uniforme et prochaine lessive", stock),
        ("Maison", "recaler", "", "dire combien j'ai de vêtements propres", recaler),

        ("Absences et trajets", "parti", "lieu",
         "je pars maintenant, retour inconnu", parti),
        ("Absences et trajets", "retour", "",
         "je suis rentré, rendez-moi mes tâches", retour),
        ("Absences et trajets", "absent", "JJ/MM JJ/MM lieu",
         "absence connue à l'avance", absent),
        ("Absences et trajets", "train", "",
         "les trains pour Saint-Dié, et quand y aller", train),
        ("Absences et trajets", "billets", "",
         "relever les confirmations SNCF de la boîte", commande_billets),

        ("Emploi du temps", "calendrier", "",
         "le lien à abonner sur le téléphone", calendrier),
        ("Emploi du temps", "collecter", "", "forcer une collecte", collecter),
        ("Emploi du temps", "conflits", "", "cours en double à départager", conflits),
        ("Emploi du temps", "groupe", "2", "changer de groupe de TD", groupe),
        ("Emploi du temps", "ecarter", "Nom du cours",
         "UE au choix que je ne suis pas", ecarter),
        ("Emploi du temps", "lien", "CODE URL", "donner l'URL d'un flux", lien),

        ("Ce compte", "demarrer", "TA_CLE_API", "relier ce compte Telegram", demarrer),
        ("Ce compte", "aide", "", "cette liste", aide),
        ("Ce compte", "oublie", "", "délier ce compte Telegram", oublie),
    ]


def texte_aide() -> str:
    """L'aide, groupée et en HTML : une liste de vingt-six lignes ne se lit pas.

    Les titres de groupe sont en gras, seule mise en forme que Telegram offre
    dans un message texte.
    """
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

    return "\n".join(lignes)


def commandes_telegram() -> list[BotCommand]:
    """Ce que Telegram propose à la saisie d'un « / »."""
    return [
        BotCommand(nom, f"{description} ({argument})" if argument else description)
        for _, nom, argument, description, _ in catalogue()
    ]


def construire() -> Application:
    application = Application.builder().token(configuration().telegram_token).build()

    for _, nom, _, _, fonction in catalogue():
        application.add_handler(CommandHandler(nom, fonction))

    # Deux alias que Telegram propose de lui-même : /start à la première
    # ouverture, /help par habitude. Ce ne sont pas des commandes de plus, ils
    # n'ont donc pas à figurer dans l'aide.
    application.add_handler(CommandHandler("start", demarrer))
    application.add_handler(CommandHandler("help", aide))
    application.add_handler(CallbackQueryHandler(bouton))

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
    LOG.info("Bot Telegram démarré : %s — %s", _identite["identifiant"], _identite["lien"])
    return True


async def demarrer_bot() -> None:
    """Démarre le bot, en réessayant tant qu'il n'y arrive pas.

    Un jeton absent est un cas normal : le bot ne démarre pas et l'API tourne
    quand même. L'appel à get_me vérifie que le jeton est valide et récupère le
    nom du bot, à afficher pour le retrouver dans Telegram.

    Les tentatives sont espacées de plus en plus, jusqu'à cinq minutes. Au
    démarrage du serveur, Docker lance le conteneur avant que le DNS soit prêt
    et la première tentative échoue sur « Temporary failure in name
    resolution » ; sans réessai, le bot restait éteint jusqu'au prochain
    redémarrage manuel alors que l'API, elle, répondait normalement.

    La boucle tourne en tâche de fond : le démarrage de l'API ne l'attend pas.
    """
    global _reconnexion

    if not configuration().telegram_token:
        LOG.warning("Pas de jeton Telegram : le bot ne démarre pas, "
                    "les notifications restent en file.")
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

    # La boucle de reconnexion peut encore tourner si Telegram n'a jamais
    # répondu : l'annuler avant de rendre la main.
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
