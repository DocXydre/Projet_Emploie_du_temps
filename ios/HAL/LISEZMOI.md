# HAL, l'application iPhone

L'application du projet : le planning du foyer, la maison, le sport, la santé et HAL. Elle est décrite en partie C de [`cahier-des-charges-hal.md`](../../cahier-des-charges-hal.md), et dessinée dans la maquette Figma (fichier « Appli », page « V2 · Liquid Glass »).

Cette version est le **lot 4** : le socle. Elle tourne sur des données fictives, sans serveur.

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

Le lot 1 (le foyer et les routes de l'appli) et le lot 3 (les notifications d'Apple) côté serveur. `Foyer` passera alors des données fictives à l'API, et `ExpediteurFictif` laissera la place au vrai client. La bêta `ios/CoachSante/` reste en service jusqu'à la bascule.
