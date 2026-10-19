# HAL, l'application iPhone

L'application du projet : le planning du foyer, la maison, le sport, la santé et HAL. Elle est décrite en partie C de [`cahier-des-charges-hal.md`](../../cahier-des-charges-hal.md), et dessinée dans la maquette Figma (fichier « Appli », page « V2 · Liquid Glass »).

Le **lot 4** a posé le socle. Le **lot 5** branche Aujourd'hui et Maison sur le serveur, les **lots 6 à 9** le sport, HAL, les réglages et iOS. Tous les lots sont faits ; l'appli a ensuite été reprise écran par écran sur la maquette. Sans compte, elle tourne sur des données fictives.

## Lancer l'appli

Il faut Xcode 26 ou plus récent, et un iPhone sous iOS 26.

```
brew install xcodegen      # une fois
cd ios/HAL
xcodegen
open HAL.xcodeproj
```

Dans Xcode, onglet **Signing & Capabilities**, choisir son équipe, puis lancer sur l'iPhone. Le `.xcodeproj` n'entre pas dans le dépôt : il se régénère depuis `project.yml`. Un fichier ajouté ou retiré demande de relancer `xcodegen`.

## Essayer dans le simulateur, sur la fausse base

Pour voir chaque écran avec des données, sans toucher à rien de réel :

```
./outils/fausse_base.sh          # depuis la racine du dépôt
```

Le script construit une base `planif_maquette` toute inventée, aux dates d'aujourd'hui, et lance l'API dessus sur `http://localhost:8000`, sans ordonnanceur ni bot : aucune notification ne part, et HAL n'est appelé que si on lui écrit. Deux comptes : `thomas` / `maquette-thomas` (administrateur, HAL démarré) et `lorette` / `maquette-lorette` (HAL pas démarré). Leurs clés d'API ne changent pas d'une fausse base à l'autre : l'appli reste connectée quand on refait la base.

Le simulateur ne colle rien dans un champ de mot de passe. En Debug, sur l'écran de connexion, l'appli lit `HAL_CONNEXION` et se connecte seule :

```
SIMCTL_CHILD_HAL_CONNEXION="http://localhost:8000 thomas maquette-thomas" xcrun simctl launch "iPhone 15" fr.docxydre.hal
```

Pour sauter le premier lancement : `xcrun simctl spawn "iPhone 15" defaults write fr.docxydre.hal serveur.accueil_a_faire -bool NO`. Le trousseau du simulateur ne garde la clé que si l'appli est signée : en ligne de commande, une signature locale suffit (`xcodebuild … CODE_SIGN_IDENTITY=-`), mais `CODE_SIGNING_ALLOWED=NO` fait perdre la connexion à chaque lancement.

Ce que le simulateur ne montre pas : Santé et l'Apple Watch, les notifications d'Apple, les widgets sur l'écran verrouillé. Ils se vérifient sur un iPhone.

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
- Cocher une tâche se confirme en haut de l'écran. Elle ne part qu'au bout de trente secondes : jusque-là, la toucher de nouveau la décoche, et la ligne montre le temps qui reste (APP-10). Mettre l'appli en arrière-plan envoie tout de suite ce qui attend. Elle part ensuite par la file d'attente (APP-3). Un appui long sur une tâche la repousse.
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

## Après les lots : la reprise sur la maquette

Chaque écran a été comparé à la maquette dans le simulateur, sur la fausse base, puis corrigé ou ajouté. Quand le cahier et la maquette diffèrent, le cahier l'emporte.

- **Aujourd'hui** : le mode édition avec sa barre « Modifier l'accueil » (1.9), la galerie (1.10), le planning de la semaine (1.12), les trains d'un week-end (1.13), le récap de HAL au-dessus de l'orbe (2.5), la séance en cours en tête tant qu'elle dure.
- **Maison** : déclarer une tâche faite, aujourd'hui, hier ou un autre jour (4.4), ce qui traîne (4.5), le mode allégé avec son partage un quart, trois quarts (4.6), les absences et voyages (4.7), « Je pars », avec ce qui doit être fait avant (4.8).
- **Sport** : l'onglet entier (3.1) et son état vide (8.7), la séance prévue et la course faite (3.3, 3.12, 3.14), la séance en cours et son repos plein écran (3.5 à 3.7), la fin et le bilan (3.8, 3.9). Pendant l'exercice, trois poids : celui que HAL a prévu, le record, et le record sur dix répétitions ; en toucher un le met dans le compteur. La charge se règle au demi-kilo, en restant appuyé sur + ou −, ou en touchant le nombre pour le taper (SAI-20).
- **Réglages** : fond et couleurs avec l'aperçu du téléphone (5.2), les calendriers à suivre avec leur état et le filtre de la fac (5.3), les calendriers abonnés en cartes, le lien jamais affiché (5.12), le profil, les limitations, les lieux, la mémoire en onglets, la pause, Santé et les notifications (5.5 à 5.11).
- **Démarrage de HAL** : l'avancée « Étape 1 sur 5 · Profil · 2/4 », les réponses en pastilles ou en cartes, le récapitulatif par blocs (7.1 à 7.13). L'attente du plan, avec la grande orbe (7.14), est redessinée mais ne se voit qu'avec un vrai appel à HAL.
- **États** : serveur injoignable, HAL qui ne répond pas, HAL en pause avec son motif et sa date de fin, conflit agrandi, thèmes (8.9 à 8.17).
- Partout, une marge en bas des pages pour que la barre d'onglets ne cache plus les derniers boutons.

Ce qui reste côté serveur est en fin de section C.13 du cahier.

## Tout le détail de Santé

L'appli lit et envoie tout ce que Santé garde, sur tout l'historique (SAN-11 à SAN-16) : pour chaque séance, ses mesures (FC, vitesse, cadence, puissance, foulée, contact au sol, oscillation, distance), ses étapes, ses tours, ses pauses, ses kilomètres et son tracé ; au quotidien, la FC de toute la journée, la VFC, la VO2max, la FC de récupération, le poids, la SpO2, la respiration, la température du poignet et l'énergie active ; le sommeil phase par phase. Toutes les sources : la montre, l'iPhone, une balance.

- Chaque type a son ancre, gardée sur le téléphone (`Sante/CollecteSante.swift`). La première fois, Santé rend l'historique par morceaux ; ensuite, seulement le nouveau. L'ancre n'avance qu'une fois le morceau envoyé : coupé, l'envoi reprend où il s'était arrêté, et le serveur ignore ce qu'il a déjà.
- L'historique avance à chaque ouverture (quarante secondes), au réveil d'iOS (quinze), et surtout iPhone branché, par une tâche de fond `fr.docxydre.hal.sante.historique` qui dure tant qu'iOS la laisse.
- Réglages, Santé (5.10) : les cases, la note sur le tracé, l'avancée de l'historique et « Tout renvoyer depuis le début ».
- Depuis iOS 27, la fenêtre de Santé demande jusqu'où remonter : il faut choisir « Toutes les données enregistrées », sinon HAL ne voit que les 30 derniers jours.

Les écrans du détail (3.22 à 3.25) lisent ce que le serveur calcule dans les séries brutes :

- **La course avec étapes** (3.22), dans la séance faite : le résumé, la carte du parcours colorée par étape, les étapes face au prévu avec les fractions côte à côte (une fraction lente en ambre), l'allure et la FC sur une même courbe, les zones, la dynamique de course. Une course sans détail garde l'écran 3.14. « Voir en grand » ouvre le parcours en plein écran (3.23) : le tracé coloré par étape, allure, FC ou dénivelé, et la feuille d'un kilomètre touché. `Sport/EcransCourse.swift`.
- **La nuit en détail** (3.24), depuis Sommeil et récupération ou Réglages, Santé : les phases heure par heure, leurs minutes face à l'habitude, la FC de la nuit, la respiration, la SpO2, la température du poignet, la VFC. Les flèches passent d'une nuit à l'autre. `Sport/EcransNuitForme.swift`.
- **Forme et corps** (3.25), depuis l'onglet Sport : VO2max, FC de récupération, poids, moyennes du quotidien, sur 30 jours, 90 jours, un an ou tout.

Sur la fausse base, le fractionné d'hier soir a tout son détail : Sport, la course de la veille.

**L'essayer dans le simulateur** : Réglages, Essais, États à forcer, « Remplir Santé et envoyer ». En Debug et dans le simulateur seulement, l'appli écrit dans Santé un fractionné inventé (mesures, étapes, tracé), trois jours de quotidien et deux nuits, puis les envoie. Sur un iPhone, ce bouton n'existe pas et l'appli n'écrit rien dans Santé.

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

Tous les lots sont faits. Le bot ne sert plus qu'à l'administrateur du serveur, l'ancien sport est retiré (lot 2), et la bêta Coach Santé est rangée dans `anciennes_fonctionnalites/coach_sante/` (lot 10). Restent :

- les trois manques côté API de la section C.13 du cahier : « Voir plus tard » sur un conflit, une tâche faite en plus qui n'existe pas encore, « Je m'en charge » sur une tâche en retard ;
- sur un vrai iPhone : les widgets iOS, l'écran verrouillé, la Live Activity, l'envoi d'une course à la montre (6.1 à 6.4) ;
- la vérification du lot 10 : deux semaines d'usage réel à deux, sans le bot.
