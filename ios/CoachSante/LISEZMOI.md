# Coach Santé

Une petite appli iPhone qui lit l'application Santé (donc l'Apple Watch) et envoie au serveur, pour le coach :

- chaque jour : les pas, la fréquence cardiaque de repos, la variabilité cardiaque, le sommeil ;
- chaque séance de la montre : type, horaires, durée, distance, dénivelé, énergie, fréquence cardiaque moyenne et maximale, allure, cadence, et le reste dans `details`.

Elle ne porte aucune règle. Elle appelle `PUT /donnees-sante/jours/{jour}` et `PUT /donnees-sante/activites/{cle}`. Renvoyer un jour ou une séance les met à jour, sans doublon. Une valeur que la montre n'a pas donnée n'est pas envoyée : ce n'est pas un zéro.

Au premier envoi, elle prend les 14 derniers jours (réglable). Le bouton « Envoyer tout l'historique », dans les réglages, envoie tout ce que Santé contient : à faire une fois, appli ouverte. Les séances de plus de 28 jours sont gardées pour le coach sans devenir des séances libres dans le planning (SAN-8).

L'envoi part à chaque ouverture de l'appli, avec le bouton « Envoyer maintenant », parfois tout seul la nuit (iOS décide de l'heure), et par l'action « Envoyer ma santé au coach » de l'appli Raccourcis.

## Avec un compte Apple gratuit

Ça marche : HealthKit et l'arrière-plan sont permis sans payer. La seule contrainte est que **l'appli expire au bout de 7 jours**. Il faut alors brancher l'iPhone au Mac et relancer depuis Xcode (Cmd+R). L'appli te prévient la veille par une notification et affiche sa date d'expiration. Ne la supprime pas : en la réinstallant par-dessus, tu gardes les réglages et la clé.

## Installer, la première fois

**Sur le Mac**

1. Installe Xcode depuis l'App Store, ouvre-le une fois, et accepte d'installer les composants.
2. Dans Xcode, va dans Réglages, puis Comptes, clique sur « + » et ajoute ton identifiant Apple.
3. Dans le Terminal :
   ```bash
   brew install xcodegen
   cd ios/CoachSante
   xcodegen
   open CoachSante.xcodeproj
   ```
4. Dans Xcode, clique sur le projet CoachSante, puis sur la cible CoachSante, puis sur l'onglet « Signing & Capabilities ». Dans « Team », choisis ton nom suivi de « (Personal Team) ». Si Xcode dit que l'identifiant `fr.docxydre.coachsante` est déjà pris, change la fin (par exemple `coachsante2`), dans `project.yml` et dans Xcode.

**Sur l'iPhone**

5. Branche l'iPhone au Mac et réponds « Se fier » sur l'iPhone.
6. Active le mode développeur : Réglages, Confidentialité et sécurité, Mode développeur, puis redémarre l'iPhone.

**Lancer l'appli**

7. Dans Xcode, en haut, choisis ton iPhone comme destination, puis fais Cmd+R.
8. Au premier lancement, l'iPhone refuse un « développeur non approuvé ». Va dans Réglages, Général, VPN et gestion de l'appareil, touche ton adresse Apple Development, puis « Faire confiance ». Relance l'appli.

## Régler l'appli

**Pour les essais, sur le Mac**

- Sur le Mac, lance `./outils/local.sh iphone`. Il ouvre l'API locale au Wi-Fi et affiche l'adresse à copier (par exemple `http://MacBook-Air-de-DocXydre.local:8000`). L'iPhone doit être sur le même Wi-Fi.
- Dans l'appli, ouvre la roue dentée.
  - Mets l'adresse et ta clé d'API, la même que pour `/demarrer` dans le bot.
  - Touche « Autoriser l'accès à Santé » et coche tout.
  - Touche « Tester la connexion ».
- iOS demande aussi l'accès au réseau local : réponds oui.
- Sur le Mac, `./outils/local.sh sante` montre ce qui est arrivé.

**Plus tard, sur le serveur**

- Installe Tailscale sur l'iPhone.
- Utilise l'adresse `https://…ts.net` du serveur (celle de `tailscale serve`).
- Le coach doit d'abord y être déployé.

## Envoi automatique le soir

L'arrière-plan d'iOS n'est pas garanti, et Santé est illisible tant que l'iPhone est verrouillé. Le plus fiable :

1. Ouvre l'appli Raccourcis, puis l'onglet Automatisation, puis « Nouvelle automatisation ».
2. Choisis « Heure de la journée » (22 h 30, avant la synthèse de 23 h) ou « Chargeur » (quand il se branche).
3. Ajoute l'action « Envoyer ma santé au coach ». Choisis « Exécuter immédiatement ».

## Les fichiers

| Fichier | Rôle |
|---|---|
| `project.yml` | Le projet, pour XcodeGen. Le `.xcodeproj` se régénère, il n'est pas versionné |
| `CoachSante/LecteurSante.swift` | La lecture de Santé : jours, sommeil, séances |
| `CoachSante/ClientAPI.swift` | Les appels à l'API, la clé dans le trousseau |
| `CoachSante/Synchro.swift` | L'envoi, la tâche de fond, l'expiration du profil |
| `CoachSante/Raccourci.swift` | L'action pour l'appli Raccourcis |
| `CoachSante/Vues/` | Les deux écrans |

Le contrat avec le serveur est testé dans `tests/test_appli_sante.py`, avec les mêmes corps que l'appli envoie.

## Ce qui n'y est pas encore

Ce que prévoit la section 9.5 du cahier des charges au-delà de la santé (la séance du jour, la saisie des séries hors réseau, la semaine à valider, les réponses du coach) passe pour l'instant par le bot Telegram.
