# Le bot des membres

Retiré en octobre 2026 (lot 2 de la partie E du cahier de HAL, ADM-1 à ADM-5).
Tout ce qu'il faisait se fait dans l'appli HAL ; l'annexe 5 du cahier donne
l'écran qui remplace chaque commande.

## Ce qui reste

`api/bot.py` ne parle plus qu'à l'administrateur du serveur : `/etat`,
`/erreurs`, `/collecter`, `/placer`, `/billets`, `/hal` et `/aide`. Il ne
transporte plus que les alertes du serveur (migration 064). Un autre compte
reçoit une seule phrase : le bot sert à l'administration, le reste est dans
l'appli. Les comptes Telegram des membres ont été déliés.

## Ce qui est gardé ici

`bot.py`, le bot tel qu'il était : menu, validations, ajouts, absences,
trains, calendriers, sport et commandes du coach. Les modules qu'il appelait
(`conversation.py`, `ajout.py`, `allegement.py`, `trajets.py`,
`api/coach/telegram.py`) sont restés dans `api/` : l'appli et les tests s'en
servent encore.
