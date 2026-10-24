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

## `conversation.py` n'existe plus

En octobre 2026, `api/conversation.py` est devenu le module de services de toute
l'API sans en avoir le nom. Il a été découpé ; `bot.py` ci-dessus l'importe encore
sous son ancien nom. Pour le remettre en service, remplacer `conv.<fonction>` :

| Fonctions | Module |
|---|---|
| `appairer`, `compte_de`, `desappairer` | `api.appairage` |
| `url_calendrier`, `url_abonnement`, `calendriers_de`, `creer_calendrier`, `supprimer_calendrier`, `renouveler_calendrier`, `comptes_actifs` | `api.abonnements` |
| `url_collectable`, `arreter_source` | `api.sources` |
| `declarer_absence`, `partir`, `rentrer` | `api.absences` |
| `notifications_a_envoyer`, `marquer_envoyee` | `api.administration` (alertes de l'administrateur seulement) |
| `_replacer` | `api.ordonnanceur.replacer` |
| `_jour` | `api.coach.clair.jour_et_mois` |
| tout le reste : `executer_action`, `planning_du_jour`, `a_valider`, `lire_creneau`, `trancher_conflit`, `en_silence`… | `api.bot_des_membres` |

`notifications_a_envoyer` ne rend plus que les alertes de l'administration : les
notifications des membres passent par l'appli.
