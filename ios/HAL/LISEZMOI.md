# HAL, l'application iPhone

L'application du projet : le planning du foyer, la maison, le sport, la santé et HAL. Elle est décrite en partie C de [`cahier-des-charges-hal.md`](../../cahier-des-charges-hal.md), et dessinée dans la maquette Figma (fichier « Appli », page « V2 · Liquid Glass »).

Le **lot 4** a posé le socle. Le **lot 5** branche Aujourd'hui et Maison sur le serveur. Sans compte, l'appli tourne sur des données fictives.

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

Le sport, la santé et HAL restent fictifs jusqu'aux lots 6 et 7.

## Ajouter une fonction

Une fonction est un module (WID-1) :

1. Un fichier dans `HAL/Modules/Catalogue/`, qui déclare un `Module` : son nom, son icône, ses tailles, son widget, et s'il en a, sa vue agrandie et son écran complet.
2. Une ligne dans `HAL/Modules/Registre.swift`.

Le module apparaît alors dans la galerie, sans rien changer d'autre. Les widgets lisent leurs données dans `Foyer`, l'unique source de l'appli : ils ne calculent rien.

## Où sont les choses

| Dossier | Contenu |
|---|---|
| `App` | Le point d'entrée |
| `Theme` | Couleurs, mesures, styles de texte, combinaisons, photo de fond |
| `Composants` | Les composants réutilisables |
| `Navigation` | La racine, la barre d'onglets, les gabarits d'écran |
| `HAL` | L'orbe, le panneau, la conversation |
| `Modules` | Le système de modules, la grille, la galerie, et le catalogue des modules |
| `Donnees` | Les modèles, les données fictives, la file d'attente |
| `Ecrans` | Les onglets et les réglages |

## La suite

Le lot 6 : le sport et la séance de musculation, hors réseau compris. La bêta `ios/CoachSante/` reste en service jusqu'à la bascule.
