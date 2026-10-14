# HAL, l'application iPhone

L'application du projet : le planning du foyer, la maison, le sport, la santé et HAL. Elle est décrite en partie C de [`cahier-des-charges-hal.md`](../../cahier-des-charges-hal.md), et dessinée dans la maquette Figma (fichier « Appli », page « V2 · Liquid Glass »).

Le **lot 4** a posé le socle. Le **lot 5** branche Aujourd'hui et Maison sur le serveur, les **lots 6a et 6b** le sport et la séance. Sans compte, l'appli tourne sur des données fictives.

## Lancer l'appli

Il faut Xcode 26 et un iPhone sous iOS 26.

```
brew install xcodegen      # une fois
cd ios/HAL
xcodegen
open HAL.xcodeproj
```

Dans Xcode, onglet **Signing & Capabilities**, choisir son équipe, puis lancer sur l'iPhone. Le `.xcodeproj` n'entre pas dans le dépôt : il se régénère depuis `project.yml`.

## Ce que fait le lot 4

- Le thème : les couleurs, les espacements, les styles de texte de la maquette, et les quatre combinaisons (THM-3).
- La photo de fond : choisie dans la photothèque, avec flou, assombrissement et couleurs réglables, et l'option de déduire les couleurs de la photo (THM-1 à THM-4). Réglages, Fond et couleurs.
- Les composants de C.4 : boutons, puces, anneaux, lignes, mesures, compteur, choix segmenté, graphiques. Réglages, Essais, Composants les montre tous ; changer de combinaison en haut les recolore.
- La barre d'onglets en verre avec l'orbe au milieu, et le panneau de HAL qui pousse le contenu et garde la conversation d'un onglet à l'autre (APP-1, ORB-1 à ORB-8). Un appui long sur l'orbe ouvre la dictée (l'interface seulement : la reconnaissance de la voix arrive au lot 7).
- Les modules et les widgets : le registre, les trois tailles, le mode édition (crayon) pour déplacer, retirer, redimensionner, la galerie pour ajouter, l'agrandissement sur place, les widgets prioritaires en tête, la séance libre toujours en bas à droite (WID-1 à WID-8).
- La file d'attente hors réseau : ce qu'on fait sans réseau est gardé sur le téléphone avec une clé d'appareil, et envoyé dans l'ordre au retour (APP-3).

Réglages, Essais, **États à forcer** permet de voir les cas sans serveur : conflit de cours, ajustement de HAL, mesure demandée, jour de muscu, foyer vide, hors réseau, mode allégé, absence, pause.

## Ce que fait le lot 5

- La connexion : l'adresse du serveur, le pseudo et le mot de passe rendent la clé d'API, gardée dans le trousseau (CNX-1, CNX-2). Un code d'invitation crée le compte et le connecte (FOY-3). « Essayer sans serveur » garde les données fictives.
- Aujourd'hui et Maison lisent `GET /appli/aujourdhui` : la journée, les tâches des deux, le conflit, les absences, le mode allégé, le chat, l'équilibre et les week-ends proposés. La réponse est gardée sur le téléphone : hors réseau, l'appli montre la dernière reçue. Tirer vers le bas recharge, et l'appli recharge seule toutes les deux minutes.
- Cocher une tâche se confirme en haut de l'écran, avec cinq secondes pour annuler, puis part par la file d'attente (APP-3). Un appui long sur une tâche la repousse.
- Le « + » : ajouter une tâche, déclarer une tâche faite, poser un créneau, une absence, le mode allégé. La séance libre et la mesure arrivent avec le sport.
- Le conflit de cours se tranche dans son widget. Un week-end proposé ouvre les trains : l'aller, le retour, et l'absence se pose toute seule.
- Réglages, Serveur et mot de passe : changer de mot de passe, se déconnecter.

HAL reste fictif jusqu'au lot 7.

## Ce que fait le lot 6a

- Santé est lue toute seule, à l'ouverture de l'appli et quand iOS la réveille, puis envoyée au serveur (SAN-10). Le code vient de la bêta Coach Santé. La fréquence cardiaque du jour nourrit son widget.
- L'onglet Sport lit `GET /appli/sport` : la semaine, la forme, l'objectif, la séance du jour avec ses exercices et leurs alternatives, les mesures demandées, les ajustements de HAL, la pause. Gardé sur le téléphone.
- La séance de musculation, prévue ou libre, se fait entièrement sans réseau : séries, « J'ai bloqué avant » et sa série intermédiaire (SAI-17, calculée sur le téléphone), changement d'exercice parmi les alternatives, repos avec retour haptique et notification, les quatre façons de terminer, le bilan. Chaque saisie porte sa clé d'appareil et part par la file : renvoyée après une coupure, elle ne crée rien de plus (SAI-9). Une séance libre ouverte sans réseau est désignée par sa clé tant que le serveur ne lui a pas donné de numéro.
- Mesure demandée : saisir ou « pas possible ». Ajustement de HAL : accepter ou refuser.

## Ce que fait le lot 6b

- La semaine à valider (3.2), d'un geste, avec « Demander un changement » qui ouvre HAL. Un bandeau la signale dans Sport.
- Sommeil et récupération sur 7, 30 ou 90 jours (3.16), la fréquence cardiaque de la journée en face du planning (3.15), la progression de chaque exercice (3.17), les objectifs avec l'avis de HAL et la feuille de route (3.18).
- Annoncer une séance libre (3.11) : HAL répond tout de suite.
- La séance à deux (3.20) : « Je viens » ou « pas cette fois ».
- Une course prévue ne se lance pas dans l'appli : elle partira sur la montre au lot 9. Faite, elle montre ce que la montre a enregistré, puis l'avis de HAL (3.14).
- Les tests de course se notent au temps, les tests de force aux répétitions.

Changer d'exercice avant de lancer (3.4) se fait pendant la séance, par le menu « Changer ».

## Ce que fait le lot 6c

- Santé dans Réglages (5.10) : le dernier envoi, « Envoyer maintenant », ce qui est lu, case par case (SAN-10).
- Les mesures : la dernière de chaque type, sa courbe, l'historique, et une saisie hors de toute fenêtre (MES-4).
- Les séances de la montre en détail, et la charge d'entraînement dans la semaine.
- Une mesure demandée n'apparaît qu'à partir du premier jour de sa fenêtre (MES-1).
- Le texte de HAL est en blanc, et les lignes des formulaires sont en verre dépoli : tout se lit sur une photo claire.

## Ce que fait le lot 7

- Le panneau de HAL parle au serveur : l'historique des échanges, le récap du soir, les éléments de chaque réponse avec leurs boutons (COA-17). Un message sans réponse est gardé sur le téléphone et repart tout seul (ORB-8).
- HAL sait ce qui est affiché : l'onglet, et la séance, la semaine ou le réglage ouvert (« Voit : Sport · Semaine du 12 oct. », COA-33).
- « Demander un changement », sur une séance, une course ou la semaine, joint l'élément en haut du panneau. HAL propose, tu valides (COA-32).
- Une action faite depuis le panneau s'annonce cinq secondes avec « Annuler ». Elle ne part qu'à la fin du délai : annuler ne laisse rien à défaire.
- Des réponses prêtes en boutons : « Oui », « Non » quand HAL pose une question, « J'ai mal quelque part » pour signaler (ORB-9, ORB-11).
- La dictée, avec le texte en direct, sur le téléphone quand il le permet (ORB-5).
- Le démarrage de HAL, écran par écran : profil, limitation, lieux, objectif, récapitulatif, avis, plan, semaine de calibrage (7.1 à 7.17). Il reprend là où on s'était arrêté.
- Réglages : profil sportif, limitations et exercices interdits, lieux, mémoire de HAL et ses versions, pause, reprendre ou repartir de zéro.

## Ce que fait le lot 8

- Le premier lancement, après une connexion ou une invitation acceptée : Santé, les notifications, les calendriers, la rencontre avec HAL (8.1 à 8.5). Chaque écran explique avant que la fenêtre d'iOS ne s'ouvre ; Santé n'est plus demandée toute seule à l'ouverture (PRE-2). Chacun a « Plus tard » (PRE-3).
- Rejoindre un foyer par un lien : l'administrateur partage `https://serveur/rejoindre/CODE`, une page qui ouvre l'appli par `hal://rejoindre`, avec le code et l'adresse du serveur déjà remplis (5.16, 5.18). Il ne reste qu'à choisir son pseudo et son mot de passe.
- Aujourd'hui dit à un compte neuf quoi faire : « Pour bien démarrer » liste ce qui manque, un calendrier, HAL, Santé, les notifications, et chaque ligne disparaît une fois faite (8.6). Maison et Sport font de même pour les tâches, la personne à inviter et Santé (8.7, 8.8). Un widget vide propose le bouton qui le remplit (WID-8).
- Serveur injoignable : le bandeau est sur les trois onglets, avec l'heure des données affichées et ce qui attend d'être envoyé (8.9, APP-2). Une clé que le serveur ne reconnaît plus propose de se reconnecter.
- Réglages, groupe Planning : les calendriers à suivre, leur état, le groupe de TD, les UE écartées, arrêter et reprendre (5.3) ; ajouter un calendrier en collant son lien, vérifié avant d'être gardé (5.4, COL-7) ; les calendriers abonnés, le lien de son planning, les calendriers composés (5.12) ; l'Historique, jour par jour, avec sa recherche (5.17).
- Réglages, Appareil : les notifications et mes heures, bilan, relance, récap et silence (5.11). L'iPhone s'enregistre auprès du serveur pour les notifications d'Apple, et s'en retire à la déconnexion (NOT-16, CNX-6).
- Réglages, Foyer et compte : le foyer, ses membres, inviter, les droits sur les tâches, passer l'administration, retirer, quitter (5.15, 5.16) ; le serveur et l'état de la connexion (5.13).

La capacité Push (`aps-environment`) est dans `project.yml` : elle demande le compte développeur payant. Réglages, Essais, « Revoir le premier lancement » le rejoue sans se déconnecter, et « Compte neuf » montre en démonstration ce que voit un compte qui arrive.

### Vérifier le lot 8

1. Sur le premier iPhone : Réglages, Le foyer, Inviter quelqu'un, puis partager le lien.
2. Sur l'autre : toucher le lien, puis « Ouvrir dans HAL ». Le code et le serveur sont remplis ; choisir un pseudo et un mot de passe.
3. Passer les quatre écrans, ou en sauter avec « Plus tard ».
4. Aujourd'hui montre « Pour bien démarrer » avec ce qui reste. Ajouter un calendrier le fait disparaître de la liste, et la journée s'affiche.

## Ce que fait le lot 9

- Des widgets iOS (IOS-1) : Sport (l'anneau de la semaine et la prochaine séance), Forme (la nuit, la FC au repos, les pas), Ta journée (maintenant et ensuite). Ils lisent ce que l'appli a gardé dans le dossier partagé du groupe `group.fr.docxydre.hal`, sans appel au serveur, et l'appli leur demande de se redessiner à chaque chargement.
- Sur l'écran verrouillé (IOS-2) : l'anneau Sport, le prochain événement, et l'orbe qui ouvre directement le panneau de HAL.
- La Live Activity de la séance (IOS-3) : l'exercice, la série et le repos, sur l'écran verrouillé et dans la Dynamic Island, compacte, minimale ou déployée avec « Passer ».
- L'envoi à la montre (MON-1) : une course ou une séance de cardio prévue part dans l'app Exercice, à son heure, avec ses étapes (les lignes prévues par HAL, ou échauffement, corps de séance et retour au calme) et ses alertes (l'allure si HAL en donne une, sinon la zone cardiaque de l'intensité). Faite, elle revient par Santé et valide la séance (MON-2).
- Toucher un widget ouvre l'appli au bon endroit : `hal://aujourdhui`, `hal://sport`, `hal://hal`, `hal://seance`.

## Ajouter une fonction

Une fonction est un module (WID-1) :

1. Un fichier dans `HAL/Modules/Catalogue/`, qui déclare un `Module` : son nom, son icône, ses tailles, son widget, et s'il en a, sa vue agrandie et son écran complet.
2. Une ligne dans `HAL/Modules/Registre.swift`.

Le module apparaît alors dans la galerie, sans rien changer d'autre. Les widgets lisent leurs données dans `Foyer`, l'unique source de l'appli : ils ne calculent rien.

## Où sont les choses

| Dossier | Contenu |
|---|---|
| `App` | Le point d'entrée, les notifications d'Apple |
| `Theme` | Couleurs, mesures, styles de texte, combinaisons, photo de fond |
| `Composants` | Les composants réutilisables |
| `Navigation` | La racine, la barre d'onglets, les gabarits d'écran |
| `HAL` | L'orbe, le panneau, la conversation |
| `Modules` | Le système de modules, la grille, la galerie, et le catalogue des modules |
| `Donnees` | Les modèles, les données fictives, la file d'attente |
| `Ecrans` | Les onglets, les réglages et les formulaires |
| `Sport` | La séance en cours, gardée sur le téléphone, et ses écrans |
| `Sante` | La lecture de Santé et son envoi |
| `PremierLancement` | Les quatre écrans d'après la connexion |
| `Montre` | L'envoi d'une course à l'app Exercice de l'Apple Watch |
| `../Partage` | Ce que l'appli partage avec ses widgets : l'instantané, la Live Activity |
| `../HALWidgets` | Les widgets iOS et la Live Activity |

## La suite

Le lot 2, les retraits : le bot réservé à l'administrateur et l'ancien sport retiré. Puis le lot 10, la bascule : tout le monde sur HAL, la bêta `ios/CoachSante/` rangée.
