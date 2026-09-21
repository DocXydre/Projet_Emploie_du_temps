"""Commandes Telegram du stock d'uniforme, retirées de api/bot.py.

Pour les rebrancher :
  - remettre ces trois fonctions dans api/bot.py ;
  - la ligne du menu :       [("Uniforme", "stock"), ("Corriger le stock", "recaler")]
  - dans _bouton_menu :       "stock": stock, "recaler": recaler
  - dans le catalogue :
        ("Maison", "stock", "", "uniforme et prochaine lessive", stock),
        ("Maison", "recaler", "", "dire combien j'ai de vêtements propres", recaler),
  - dans le traitement des boutons :
        if genre == "recal":
            await _appliquer_recalage(requete.message, choix, int(identifiant))
            return
"""


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


async def stock(update: Update, contexte: ContextTypes.DEFAULT_TYPE) -> None:
    compte = await _appelant(update)
    if compte is None:
        return await _refuser(update)

    texte = await asyncio.to_thread(conv.etat_du_stock, compte["id_utilisateur"])
    await update.effective_message.reply_text(texte)
