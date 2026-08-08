# Cahier des charges v2 : Système de planification personnelle et de logistique domestique

Version 2.0
Auteur : Thomas Mathis
Statut : à valider avant démarrage du lot 0

---

## 0. Comment lire ce document

La version 1 décrivait des règles métier. Cette version 2 ajoute ce qui manquait pour pouvoir coder : le modèle de données, l'algorithme de décision, la gestion des conflits, la résilience des sources externes, et un plan de réalisation découpé en lots livrables.

Les points marqués **[À TRANCHER]** sont des décisions qui t'appartiennent et qui bloquent le lot concerné.

---

## 1. Contexte et objectifs

### 1.1 Problème résolu

Trois emplois du temps hétérogènes se croisent (cours à l'IDMC, shifts McDonald's, disponibilités de Lorette) et génèrent une charge mentale permanente : quand faire du sport, quand lancer une lessive pour ne pas se retrouver sans uniforme propre, quand partir à Saint-Dié, quelle tâche ménagère est en retard. Aucun outil du marché ne croise ces sources et n'applique des règles personnelles aussi spécifiques.

### 1.2 Objectifs

1. **Objectif d'usage** : que le système soit réellement utilisé tous les jours et remplace la charge mentale par des notifications fiables.
2. **Objectif technique** : constituer un projet de référence pour une candidature en alternance, avec une architecture défendable en entretien et un code lisible.

Ces deux objectifs sont classés dans cet ordre. En cas de conflit, l'usage réel gagne. Un système sur-architecturé jamais terminé n'a aucune valeur en entretien.

### 1.3 Critères de succès

| Critère | Cible |
|---|---|
| Utilisation quotidienne effective | 30 jours consécutifs sans retour au papier ou au calendrier manuel |
| Fiabilité du stock uniforme | Zéro rupture d'uniforme sur 3 mois |
| Quota sportif | Écart moyen inférieur à 0,5 séance par semaine sur l'objectif |
| Confiance dans le planning | Moins de 10 % des tâches proposées rejetées comme irréalistes |
| Stabilité | Moins de 2 déplacements par semaine d'une tâche déjà notifiée |

### 1.4 Nature du livrable

**Le livrable de ce cahier des charges est l'API, et rien d'autre.** Aucune interface graphique n'est développée dans ce projet.

Conséquences à assumer dès le premier jour :

- Toute fonctionnalité doit être pilotable sans écran : par un appel HTTP, par un bouton de notification, ou par une commande du bot.
- Le système doit être **utilisable au quotidien sans aucun front**. C'est ce que permet la combinaison du canal de notification à boutons et de l'export ICS.
- Tout ce qu'un futur client devra afficher doit exister comme donnée exposée par l'API, y compris les motifs de décision du moteur.
- La documentation d'interface (OpenAPI) est un livrable au même titre que le code : c'est le contrat sur lequel s'appuiera l'application visuelle plus tard.

Une application Angular viendra ensuite, dans un projet séparé, et consommera cette API sans aucune adaptation côté serveur. Si une adaptation s'avère nécessaire à ce moment, c'est que l'API aura été mal conçue.

### 1.5 Périmètre exclu

Ces éléments sont volontairement hors périmètre pour éviter l'effet tunnel. Ils sont notés pour mémoire.

- Toute interface graphique, web ou mobile.
- Multi-tenant ou ouverture à d'autres utilisateurs que Thomas et Lorette.
- Gestion budgétaire ou de courses alimentaires.
- Machine learning ou prédiction de préférences.
- Scraper dédié à l'école de Lorette (saisie manuelle en v1).

---

## 2. Glossaire et concepts fondamentaux

Ce vocabulaire est contractuel : il doit se retrouver tel quel dans le code, les tables et les endpoints.

| Terme | Définition |
|---|---|
| **Contrainte dure** | Occupation subie et non déplaçable : cours, shift McDonald's, trajet en train validé, sommeil. |
| **Disponibilité** | Intervalle de temps libre d'un utilisateur, calculé par soustraction des contraintes dures sur l'horizon. |
| **Définition de tâche** (`TaskDefinition`) | Le modèle récurrent : "passer l'aspirateur tous les 2 à 3 jours". Ne porte aucune date. |
| **Occurrence** (`TaskInstance`) | Une exécution concrète d'une définition, avec une fenêtre d'échéance, un état, un assigné et éventuellement un créneau planifié. |
| **Fenêtre d'échéance** | Couple `echeance_min` / `echeance_max`. Une tâche n'a jamais une date unique, elle a une plage acceptable. |
| **Créneau planifié** | Proposition datée du moteur pour une occurrence. Peut bouger tant qu'elle n'est pas épinglée. |
| **Épinglage** | Verrouillage d'un créneau déjà communiqué à l'utilisateur ou accepté par lui. Un créneau épinglé ne bouge plus, sauf conflit avec une contrainte dure. |
| **Statut global** | État de l'utilisateur qui modifie les règles applicables : `ACTIF`, `MALADE`, `ABSENT`. |
| **Collecteur** | Composant qui récupère des données d'une source externe (fichier ICS, portail McDo, SUAPS, boîte mail) et les normalise. |
| **Réplanification** | Exécution du moteur qui produit un nouveau plan à partir de l'état courant. Doit être idempotente. |
| **Dette de tâches** | Ensemble des occurrences gelées ou dépassées à rattraper après un retour à `ACTIF`. |

Note de nommage : le statut `LUSSE` de la v1 devient `ABSENT`, avec un champ `lieu` optionnel. Un statut ne doit pas porter un nom de commune, sinon la règle n'est plus réutilisable pour une autre absence (vacances, week-end ailleurs, déplacement).

---

## 3. Acteurs, rôles et permissions

### 3.1 Acteurs humains

| Acteur | Rôle | Droits |
|---|---|---|
| Thomas | Administrateur | Tout : configuration des règles, forçage de créneaux, création et suppression de définitions, accès aux journaux techniques |
| Lorette | Utilisatrice standard | Consulter son planning, valider ses tâches, saisir son emploi du temps, déclarer son statut, refuser une assignation, voir les créneaux de sport proposés |

### 3.2 Acteurs techniques

| Acteur | Rôle |
|---|---|
| Ordonnanceur | Déclenche les collectes et les réplanifications périodiques |
| Collecteurs | Récupèrent les données externes |
| Moteur de planification | Produit le plan |
| Notificateur | Émet et escalade les notifications |

### 3.3 Règles de permission

- Une occurrence assignée à Lorette ne peut être validée que par Lorette ou par Thomas (mode dépannage, tracé dans le journal).
- Le forçage d'un créneau hors règles est réservé à l'administrateur.
- Toute action manuelle est journalisée avec auteur, horodatage et valeur précédente.

---

## 4. Architecture technique

### 4.1 Vue d'ensemble

Deux services applicatifs et une base, en conteneurs sur une seule machine. Les consommateurs sont externes au projet.

```
     Consommateurs (hors périmètre de ce projet)
     ┌──────────────┬──────────────┬──────────────────┐
     │ Bot Telegram │ Calendrier   │ Future app       │
     │ (natif API)  │ (flux ICS)   │ Angular          │
     └──────────────┴──────┬───────┴──────────────────┘
                                 │ HTTPS
                    ┌────────────▼─────────────┐
                    │  Caddy (reverse proxy)   │
                    └────────────┬─────────────┘
                                 │
        ┌────────────────────────▼───────────────────────┐
        │  Cœur métier : Spring Boot (Java 21)           │
        │  - modèle de données et persistance            │
        │  - moteur de planification                     │
        │  - ordonnanceur (@Scheduled)                   │
        │  - notifications et escalade                   │
        │  - endpoints HTTP                              │
        └───────┬─────────────────────────────┬──────────┘
                │ HTTP interne                │ JDBC
        ┌───────▼───────────────┐    ┌────────▼─────────┐
        │ Collecteurs : Python  │    │  PostgreSQL 16   │
        │ FastAPI + Playwright  │    └──────────────────┘
        │ - portail McDonald's  │
        │ - créneaux SUAPS      │            ┌──────────────────┐
        │ - lecture ICS IDMC    │            │  ntfy / Telegram │
        │ - boîte mail dédiée   │◄───────────┤  (notifications) │
        └───────────────────────┘            └──────────────────┘
```

### 4.2 Justification des choix

**Spring Boot pour le cœur.** Le code de valeur est du code métier : règles, priorités, machines à états, calculs de fenêtres. Java reste très confortable pour ça, c'est ta langue maternelle technique, et le couple Spring Boot plus Angular correspond à ce que recrutent les entreprises visées pour l'alternance.

**Python isolé pour la collecte.** Le scraping est la partie la plus fragile et la plus gourmande du système : un Chromium headless consomme plusieurs centaines de mégaoctets et casse à chaque refonte de site. L'isoler dans son propre conteneur garantit qu'un scraper mort ou fuyant ne fait pas tomber le planificateur. C'est aussi ton point fort et ça donne une frontière de service naturelle à raconter en entretien.

**Pas de file de messages, pas d'orchestrateur.** Pour deux utilisateurs et quelques dizaines d'événements par jour, Kafka ou Kubernetes seraient du décor. Un appel HTTP interne et une table de travail suffisent, et un recruteur technique préfère largement une architecture proportionnée à une architecture gonflée.

**ntfy ou Telegram plutôt que le push web natif.** Les notifications push mobiles imposent une gestion de certificats et de tokens sans valeur ici. Un canal ntfy auto-hébergé ou un bot Telegram donne le même résultat en une journée de travail. **[À TRANCHER]** : ntfy (auto-hébergé, plus propre) ou Telegram (plus riche, boutons de validation intégrés). Recommandation : Telegram, parce que les boutons inline permettent de valider une tâche sans ouvrir l'application.

### 4.3 Infrastructure cible

| Élément | Choix |
|---|---|
| Machine | Mini PC d'occasion (OptiPlex Micro, ThinkCentre Tiny ou EliteDesk Mini), i5 8e génération, 16 Go, SSD |
| OS | Debian stable |
| Conteneurisation | Docker Compose |
| Reverse proxy | Caddy, HTTPS automatique |
| Accès administration | Tailscale, aucun port SSH exposé |
| Déploiement | GitHub Actions vers le serveur, comme pour le portfolio |
| Sauvegarde | Dump PostgreSQL quotidien, chiffré, copié hors machine, rétention 30 jours |
| Supervision | Endpoint de santé par service, alerte sur le canal de notification si un service ou un collecteur est mort |

L'Atom actuel reste dédié au portfolio statique. Il n'a ni la mémoire ni un jeu d'instructions compatible avec une JVM moderne et un navigateur headless.

### 4.4 Une API ou plusieurs ?

Question légitime, et la réponse est nuancée.

**Une seule API publique**, celle du cœur métier. C'est elle que consommeront le bot, le calendrier et la future application Angular. La découper en plusieurs API exposées séparément (une API tâches, une API planning, une API stock) créerait un monolithe distribué : mêmes données, mêmes transactions, mais réparties sur plusieurs processus, avec de la latence et de la complexité en plus et zéro bénéfice pour deux utilisateurs.

**Un service interne non exposé**, celui des collecteurs Python. Il a sa propre interface HTTP, mais elle n'est accessible que depuis le réseau Docker interne. Ce n'est pas une API produit, c'est une frontière technique justifiée par l'isolation des scrapers.

**Ce qui compte vraiment, c'est le découpage interne.** Le cœur métier est un monolithe modulaire : chaque module (planification, tâches, stock, déplacements, sport, travail, notifications) a son propre paquet, ses propres entités, et communique avec les autres par des interfaces explicites, jamais en attaquant directement les tables du voisin. Concrètement :

```
fr.thomasmathis.planif
├── commun/          (entités partagées, horloge, fuseau, journal)
├── contraintes/     (occupations, disponibilités, collecte)
├── taches/          (définitions, occurrences, dépendances)
├── planification/   (interface Planificateur et implémentation)
├── stock/           (unités, projection, déclenchement lessive)
├── deplacements/    (fenêtres, trajets, confirmation)
├── sport/           (quota, rotation, duo)
├── travail/         (shifts, pointages, synthèse)
├── notifications/   (canaux, escalade, validation)
└── api/             (contrôleurs, DTO, sécurité)
```

Cette discipline te donne le meilleur des deux mondes : le confort d'un seul déploiement aujourd'hui, et la possibilité d'extraire un module en service séparé demain si un besoin réel apparaît. C'est aussi un argument solide en entretien : savoir expliquer pourquoi tu n'as **pas** fait de microservices vaut mieux que d'en avoir fait sans raison.

**Règle de découpage à respecter** : un module ne dépend jamais des entités internes d'un autre module. Il passe par une interface exposée par ce module. Si tu constates qu'un module a besoin de lire trois tables d'un autre, c'est que la frontière est mal placée.

### 4.5 Versionnement de l'interface

- Préfixe de version dans les chemins : `/api/v1/...`.
- Spécification OpenAPI générée automatiquement et versionnée dans le dépôt.
- Aucune rupture de contrat sans changement de version, même si tu es le seul client. C'est l'habitude qui compte.
- Format de date en ISO 8601 avec fuseau explicite, partout, sans exception.
- Réponses d'erreur normalisées : code, message lisible, détail technique, identifiant de corrélation.

---

## 5. Modèle de données

Schéma logique. Les noms sont indicatifs mais la structure est le cœur du système.

### 5.1 Utilisateurs et statuts

**`utilisateur`** : `id`, `nom`, `role`, `fuseau`, `canal_notification`, `actif`

**`statut_utilisateur`** : `id`, `utilisateur_id`, `type` (`ACTIF`, `MALADE`, `ABSENT`), `lieu` (nullable), `debut`, `fin_prevue` (nullable), `fin_reelle` (nullable), `commentaire`

Un seul statut ouvert par utilisateur à un instant donné. L'historique est conservé.

**`regle_statut`** : `id`, `type_statut`, `categorie_tache`, `effet` (`GELER`, `REPORTER`, `REASSIGNER`, `MAINTENIR`), `cible_reassignation`

Cette table est essentielle : elle rend les effets d'un statut configurables au lieu de les coder en dur. C'est ce qui te permettra d'ajouter un statut `VACANCES` sans toucher au moteur.

### 5.2 Occupations et disponibilités

**`source_contrainte`** : `id`, `code` (`IDMC_ICS`, `MCDO_PORTAIL`, `SAISIE_MANUELLE`, `SNCF_MAIL`, `SUAPS`), `type_collecte`, `derniere_collecte_ok`, `derniere_collecte_tentee`, `etat_sante` (`OK`, `DEGRADE`, `MORT`), `ttl_fraicheur_heures`

**`occupation`** : `id`, `utilisateur_id`, `source_id`, `type` (`COURS`, `SHIFT`, `TRAJET`, `SOMMEIL`, `PERSO`), `debut`, `fin`, `lieu`, `libelle`, `cle_externe`, `annulee`, `collectee_le`

La `cle_externe` (UID d'un événement ICS, identifiant de shift) permet la réconciliation entre deux collectes : on met à jour au lieu de dupliquer.

**`trajet`** : `id`, `utilisateur_id`, `sens` (`ALLER`, `RETOUR`), `depart`, `arrivee`, `gare_depart`, `gare_arrivee`, `etat` (`SUGGERE`, `CONFIRME`, `ANNULE`), `source_confirmation` (`MAIL`, `MANUEL`), `reference_billet`

### 5.3 Tâches

**`definition_tache`** : `id`, `code`, `libelle`, `categorie` (`MENAGE`, `LINGE`, `VAISSELLE`, `ANIMAL`, `SPORT`, `ADMIN`), `priorite`, `duree_minutes`, `intervalle_min_jours`, `intervalle_max_jours`, `assignation_par_defaut`, `gelable`, `fenetre_horaire_debut`, `fenetre_horaire_fin`, `active`

**`dependance_tache`** : `id`, `definition_source_id`, `definition_cible_id`, `type` (`DECLENCHE_APRES`), `delai_max_heures`

Exemple : `POUSSIERE` déclenche `ASPIRATEUR` dans les 24 heures.

**`occurrence_tache`** : `id`, `definition_id`, `assigne_a`, `echeance_min`, `echeance_max`, `creneau_debut`, `creneau_fin`, `epinglee`, `etat`, `origine` (`AUTOMATIQUE`, `MANUELLE`, `DEPENDANCE`, `RATTRAPAGE`), `validee_le`, `validee_par`, `occurrence_parente_id`

États d'une occurrence :

```
PLANIFIEE ──► NOTIFIEE ──► VALIDEE
    │             │
    │             ├──► REPORTEE ──► (nouvelle occurrence)
    │             └──► REFUSEE ───► (réassignation ou report)
    └──► GELEE ──► (dégel : retour à PLANIFIEE)
                 └──► ANNULEE
```

### 5.4 Stock et linge

**`article_stock`** : `id`, `code` (`TSHIRT_MCDO`, `PANTALON_MCDO`), `libelle`, `quantite_totale`, `seuil_securite`, `jours_usage_par_unite`, `duree_sechage_heures`

**`unite_stock`** : `id`, `article_id`, `numero`, `etat` (`PROPRE`, `EN_USAGE`, `SALE`, `EN_LAVAGE`, `EN_SECHAGE`), `disponible_a_partir_de`

Le champ `disponible_a_partir_de` est le correctif majeur par rapport à la v1 : un vêtement lavé n'est pas un vêtement portable. Un cycle lancé à 21h45 se termine vers 23h30, le linge est étendu et redevient disponible seulement après la durée de séchage paramétrée.

**`mouvement_stock`** : `id`, `unite_id`, `type`, `date`, `occurrence_liee_id`

### 5.5 Planification et journal

**`plan`** : `id`, `genere_le`, `horizon_debut`, `horizon_fin`, `version`, `declencheur` (`CRON`, `MANUEL`, `EVENEMENT`)

**`decision_plan`** : `id`, `plan_id`, `occurrence_id`, `creneau_debut`, `creneau_fin`, `score`, `motif`

Conserver le motif d'une décision ("placée à 18h car dernier créneau de 3h avant échéance") est ce qui rendra le système débogable et compréhensible. C'est aussi ce qui fait la différence entre un outil dans lequel on a confiance et une boîte noire qu'on désinstalle.

**`journal_evenement`** : `id`, `date`, `acteur`, `type`, `entite`, `entite_id`, `valeur_avant`, `valeur_apres`

**`notification`** : `id`, `occurrence_id`, `utilisateur_id`, `canal`, `niveau_escalade`, `envoyee_le`, `lue_le`, `contenu`

---

## 6. Moteur de planification

C'est le cœur du système et la partie que la v1 ne décrivait pas du tout.

### 6.1 Principe

Le moteur ne fait pas de magie : il applique un algorithme glouton par priorité sur des créneaux libres, avec un backtracking limité. Il est encapsulé derrière une interface `Planificateur` afin de pouvoir être remplacé plus tard par un solveur de contraintes (Timefold) sans toucher au reste.

### 6.2 Horizon et déclenchement

- Horizon glissant de **21 jours**.
- Réplanification déclenchée par :
  - le cron nocturne (3h00),
  - une collecte qui modifie une contrainte dure,
  - une validation, un report ou un refus de tâche,
  - une action manuelle (bouton de forçage),
  - un changement de statut global.
- Une réplanification doit être **idempotente** : deux exécutions consécutives sans changement d'entrée produisent le même plan.
- Un verrou applicatif empêche deux réplanifications simultanées.

### 6.3 Hiérarchie de priorités

C'est la règle d'arbitrage principale. Le nombre le plus bas gagne toujours.

| Niveau | Contenu | Déplaçable |
|---|---|---|
| P0 | Contraintes dures : cours, shifts, trajets confirmés, sommeil | Jamais |
| P1 | Tâches vitales non gelables : litière, lessive uniforme sous seuil de sécurité | Non, seulement avancées |
| P2 | Machines contraintes par un horaire : lessive de blanc, lave-vaisselle | Dans leur fenêtre |
| P3 | Sport, jusqu'au quota minimum hebdomadaire | Oui |
| P4 | Ménage récurrent standard et tâches dépendantes | Oui |
| P5 | Bonus : séances de sport au-delà du quota, piscine, grand ménage | Oui, abandonnable |

### 6.4 Algorithme, passe par passe

**Passe 1 : calcul des disponibilités.**
Charger toutes les occupations sur l'horizon, y ajouter les plages de sommeil et les temps de trajet, puis soustraire de la journée pour obtenir la liste des intervalles libres par utilisateur. Chaque intervalle porte un lieu déduit (domicile, faculté, hors zone).

**Passe 2 : application des statuts.**
Pour chaque statut ouvert, appliquer les règles de `regle_statut` : masquer les disponibilités, geler les catégories concernées, réassigner ce qui doit l'être.

**Passe 3 : génération des occurrences manquantes.**
Pour chaque définition active, si aucune occurrence ouverte n'existe, en créer une avec sa fenêtre calculée depuis la **date de dernière validation réelle** et non depuis la date théorique. Générer aussi les occurrences issues de dépendances et les rattrapages de dette.

**Passe 4 : calcul du stock et des lessives.**
Simuler la consommation d'uniforme sur les shifts connus, unité par unité, en tenant compte des délais de séchage. Dès qu'une projection passe sous le seuil de sécurité, créer une occurrence `LESSIVE_TRAVAIL` avec une échéance maximale calculée ainsi :

```
echeance_max = debut_shift_menace - duree_sechage - duree_cycle
```

Si cette échéance est déjà dépassée au moment du calcul, l'occurrence passe en alerte critique immédiate.

**Passe 5 : épinglage.**
Marquer comme épinglées toutes les occurrences déjà notifiées, acceptées ou en cours. Elles sont retirées de l'espace de recherche.

**Passe 6 : placement glouton.**
Trier les occurrences restantes par priorité croissante, puis par `echeance_max` croissante, puis par durée décroissante. Pour chacune, chercher le premier créneau compatible :

- durée disponible suffisante, temps de trajet inclus,
- fenêtre horaire de la définition respectée,
- lieu compatible,
- règles spécifiques de la catégorie (une seule séance de sport par jour, machine après 21h45, etc.),
- assigné disponible.

**Passe 7 : backtracking limité.**
Si une occurrence de priorité P0 à P2 ne trouve pas de place, tenter de déplacer les occurrences non épinglées de priorité strictement inférieure déjà placées, dans la limite de 3 déplacements. Au delà, échec contrôlé.

**Passe 8 : gestion des échecs.**
Une occurrence non plaçable n'est jamais supprimée silencieusement. Elle passe en état `NON_PLANIFIABLE` avec un motif lisible et déclenche une notification d'information : "Impossible de caser une séance de sport cette semaine, quota à 2 sur 3."

**Passe 9 : différentiel et notifications.**
Comparer le nouveau plan au précédent. Émettre une notification uniquement pour les changements qui concernent l'utilisateur, pas pour chaque recalcul interne.

**Passe 10 : persistance.**
Écrire le plan, les décisions avec leur motif, et le journal.

### 6.5 Règle de stabilité

Un créneau déjà notifié ne bouge que si :

1. une contrainte dure le rend impossible (nouveau shift, cours déplacé),
2. l'utilisateur le demande explicitement,
3. une tâche de priorité supérieure ne trouve aucune autre place.

Dans le cas 3, l'utilisateur reçoit une notification expliquant pourquoi le créneau a bougé. Sans cette règle, le planning change tous les matins et devient inutilisable.

---

## 7. Modules fonctionnels détaillés

### 7.1 Module A : collecte des contraintes dures

#### A.1 Contrat commun des collecteurs

Tout collecteur respecte le même contrat, sans exception :

1. `recuperer()` : obtient les données brutes.
2. `normaliser()` : produit une liste d'occupations avec clé externe.
3. `publier()` : envoie au cœur métier, qui réconcilie par clé externe (création, mise à jour, annulation).
4. `sante()` : renvoie l'état du collecteur.

Règles de résilience obligatoires :

- Chaque source a un **TTL de fraîcheur**. Passé ce délai sans collecte réussie, l'état passe à `DEGRADE`, puis `MORT`.
- Une source `MORT` déclenche une notification à l'administrateur et bascule la source en saisie manuelle.
- Le moteur ne doit **jamais** planifier sur des données périmées sans le signaler. Un planning silencieusement faux est pire que pas de planning.
- Toute collecte est journalisée avec son résultat, sa durée et le nombre d'éléments modifiés.
- Un collecteur en échec ne réessaie pas en boucle : backoff exponentiel, 5 tentatives maximum, puis attente du prochain cycle.

#### A.2 Emploi du temps IDMC (fichier ICS)

- Récupération de l'URL ICS de l'ADE de l'Université de Lorraine.
- Parsing avec réconciliation par UID.
- Détection des changements : salle, horaire, annulation. Un cours qui bascule de l'après-midi au matin doit déclencher une réplanification immédiate et une notification.
- Cron : toutes les nuits, plus une collecte toutes les 4 heures en période de cours (les modifications ADE tombent souvent en journée).
- Endpoint de forçage manuel de la collecte, appelable depuis le bot ou en HTTP direct.
- **[À TRANCHER]** : l'URL ICS de l'ADE est-elle stable d'une année sur l'autre, ou faut-il prévoir un champ de configuration modifiable ? Prévoir le champ dans tous les cas.

#### A.3 Emploi du temps de Lorette

- Saisie manuelle par elle, via un formulaire simple : jour, plage horaire, récurrence.
- Deux modes : récurrent hebdomadaire, et exception ponctuelle.
- Alternative à évaluer : import d'un ICS si son école en fournit un, ou saisie par abonnement à un calendrier partagé.
- **[À TRANCHER]** : est-ce que son école fournit un ICS ? Si oui, le module A.2 se réutilise à l'identique et c'est deux jours de travail économisés.

#### A.4 Portail McDonald's

Le point le plus fragile du système. Traitement prudent :

- Scraping avec Playwright, session stockée et réutilisée, pas de reconnexion à chaque cycle.
- Extraction des horaires prévisionnels sur environ 2,5 semaines.
- Extraction des pointages réels par quart d'heure.
- Fréquence : deux fois par jour, pas plus. Un scraping agressif est le meilleur moyen de se faire bloquer.
- **Mode dégradé obligatoire** : un écran de saisie manuelle des shifts, utilisable en 30 secondes, qui prend le relais si le scraper meurt. Ce mode doit exister dès le premier jour, pas être ajouté après la première panne.
- Les identifiants sont chiffrés en base, jamais dans le code ni dans un fichier de configuration versionné.
- Si le portail impose une authentification à deux facteurs, le scraping automatique devient impossible et le mode manuel devient le mode principal. À vérifier avant de commencer le lot 5.
- Considération de bon sens : ce module reste un usage personnel de tes propres données. Il n'est pas destiné à être publié ni redistribué, et le dépôt du projet ne doit contenir aucune donnée réelle.

#### A.5 Créneaux de piscine (SUAPS)

- Scraping des créneaux publics.
- Fréquence hebdomadaire, plus un rafraîchissement à la demande.
- Mode dégradé : saisie manuelle d'une grille horaire type, valable tout le semestre.

#### A.6 Boîte mail dédiée (confirmation de billets)

Choix d'architecture important : ne pas utiliser l'API Gmail avec des scopes larges sur ta boîte principale. À la place :

- Créer une adresse dédiée (par exemple `sncf@thomasmathis.me`).
- Y transférer automatiquement les mails de confirmation depuis la boîte principale, via une règle de transfert.
- Le collecteur lit cette boîte en IMAP.

Avantages : pas d'OAuth Google à maintenir, pas de token à renouveler, aucun accès du système à ta correspondance personnelle, et un périmètre de données trivial à expliquer. C'est plus simple à coder et bien plus défendable.

Extraction attendue : numéro de dossier, gares, date et heure de départ et d'arrivée, sens du trajet.

---

### 7.2 Module B : déplacements

#### B.1 Détection d'opportunité

Le moteur cherche sur l'horizon une fenêtre continue de **48 heures** sans cours ni shift. Paramétrable.

#### B.2 Règles de proposition

**Aller, le soir :**
- Départ le soir du dernier shift ou cours.
- Battement minimum de 30 minutes entre la fin de l'activité et le départ du train.
- Battement réductible à 20 minutes s'il s'agit du dernier train de la journée.
- Temps de trajet jusqu'à la gare inclus dans le calcul.

**Aller, le matin :**
- Si aucun train du soir n'est compatible, proposer le premier train disponible le lendemain à partir de 9h00.

**Retour :**
- Le plus tard possible dans la fenêtre.
- Exception : si le quota sportif hebdomadaire est en retard, avancer le retour à l'après-midi pour permettre une séance le soir même. Le moteur doit vérifier qu'une séance est effectivement plaçable avant d'avancer le retour, sinon la règle coûte du temps pour rien.

#### B.3 Source des horaires de train

**[À TRANCHER]** et c'est un vrai sujet : la v1 supposait implicitement que le système connaît les horaires SNCF. Trois options :

1. **Grille horaire statique** saisie une fois par semestre. La ligne Nancy vers Saint-Dié a peu de trains et des horaires stables. Solution la plus simple, largement suffisante, recommandée pour la v1.
2. **API SNCF ouverte** (navitia.io, jeton gratuit). Plus propre, données réelles, environ deux jours de travail.
3. Scraping d'un site d'horaires. À éviter, fragile et sans valeur ajoutée.

Recommandation : option 1 en v1, option 2 au lot 8 si le besoin se confirme.

#### B.4 Confirmation et verrouillage

- Un trajet proposé est à l'état `SUGGERE` et n'a aucun effet sur le planning.
- Dès qu'un mail de confirmation est détecté, le trajet passe à `CONFIRME`, une occupation `TRAJET` est créée, le statut `ABSENT` est programmé sur la période, et une réplanification est déclenchée.
- **Forçage** : si un billet est acheté en dehors des recommandations, la détection par mail suffit à créer le trajet. Le système ne discute pas : la réalité gagne sur la règle.
- Saisie manuelle possible si le mail n'est pas détecté.

---

### 7.3 Module C : sport

#### C.1 Musculation, règles de placement

| Règle | Valeur |
|---|---|
| Quota minimum | 3 séances par semaine |
| Mise à l'échelle | Si le taux d'occupation hebdomadaire est inférieur à un seuil paramétrable, proposer une 4e séance en priorité P5 |
| Durée de séance | 1h30 |
| Créneau requis depuis le domicile | 2h30 (1h30 plus 2 fois 20 à 30 min de trajet) |
| Créneau requis depuis la faculté | 3h00 (trajet de 30 min à l'aller) |
| Créneau alternatif du soir | 18h00 |
| Créneau tardif | 21h00 à 23h00, uniquement si le premier cours du lendemain commence à 10h00 ou plus tard |
| Limite | Une seule séance de sport par jour, piscine comprise |
| Espacement | Au moins 24 heures entre deux séances (à confirmer) |

Le calcul du créneau requis doit dériver du lieu réel de l'utilisateur avant le créneau, pas d'une constante. C'est le rôle du champ `lieu` sur les intervalles de disponibilité.

#### C.2 Contenu des séances

- Rotation stricte entre 3 types de séances, dans l'ordre, avec reprise là où la rotation s'était arrêtée.
- Le titre de chaque séance est renommable manuellement sans casser la rotation.
- **[À TRANCHER]** : veux-tu stocker le détail des exercices et des charges ? Si oui, cela devient un module à part entière (carnet d'entraînement) et je le mettrais hors périmètre v1.

#### C.3 Forçage

Thomas peut ajouter une séance qui ne respecte aucune règle de durée ou de créneau. Elle est marquée `origine = MANUELLE`, épinglée d'office, et compte dans le quota.

#### C.4 Séances en duo

- Les créneaux de salle proposés à Thomas sont visibles par Lorette avec un indicateur de disponibilité.
- Lorette peut signaler "je viens" sur un créneau.
- Si elle le fait, Thomas reçoit une proposition d'ajustement de son propre horaire pour aligner les deux, dans la limite d'un décalage paramétrable (par exemple 1 heure).
- L'ajustement n'est jamais automatique : il est proposé et accepté.
- La piscine est exclue du duo.

#### C.5 Piscine

- Insertion sur les créneaux SUAPS récupérés, typiquement vers 12h30 ou 14h00.
- Priorité P5 par défaut.
- Passe en P3 si le quota de musculation de la semaine ne peut pas être atteint : une séance de piscine compense alors une séance manquante.
- Compte dans la limite d'une séance de sport par jour.

---

### 7.4 Module D : logistique de l'appartement

#### D.1 Stock d'uniforme, modélisation à l'unité

| Article | Quantité | Usage | Seuil de sécurité |
|---|---|---|---|
| T-shirt McDo | 3 | 1 jour de shift par unité | 1 |
| Pantalon McDo | 2 | 2 jours de shift par unité | 1 |

Cycle de vie d'une unité :

```
PROPRE ──► EN_USAGE ──► SALE ──► EN_LAVAGE ──► EN_SECHAGE ──► PROPRE
                                                    │
                                     disponible_a_partir_de = fin_cycle + duree_sechage
```

La durée de séchage est paramétrable par article. Valeur de départ suggérée : 24 heures pour un t-shirt, 36 heures pour un pantalon. Ce paramètre doit être ajustable facilement, parce que tu le corrigeras après la première mauvaise surprise.

#### D.2 Algorithme de projection du stock

1. Lister les shifts connus sur l'horizon, par ordre chronologique.
2. Pour chaque shift, décrémenter le stock projeté selon la règle d'usage de chaque article.
3. Identifier le premier shift où le stock projeté d'un article passe sous son seuil de sécurité.
4. Calculer l'échéance maximale de lancement de la lessive.
5. Créer l'occurrence `LESSIVE_TRAVAIL` en priorité P1.
6. Si l'échéance calculée est déjà passée, notifier immédiatement en alerte critique.

Ce module doit fonctionner même quand le scraper McDo est en panne, à partir des shifts saisis manuellement.

#### D.3 Machines

| Tâche | Fréquence | Contrainte |
|---|---|---|
| Lessive vêtements de travail | Sur alerte de stock | Lancement à partir de 21h45 |
| Lessive de blanc | Au moins 1 fois par semaine | Lancement à partir de 21h45 |
| Lave-vaisselle | Tous les 3 à 4 jours | Lancement à partir de 21h45 |

- Contrainte physique à modéliser : une seule machine à laver, donc deux lessives ne peuvent pas être lancées le même soir. Le lave-vaisselle est indépendant.
- Notification de fin de cycle : programmée à l'heure de lancement plus la durée du cycle, pour penser à étendre ou vider.
- La validation de "lessive lancée" déclenche la transition d'état des unités de stock concernées.
- **[À TRANCHER]** : la contrainte de 21h45 vient sans doute des heures creuses. Si le contrat a une plage précise, autant la paramétrer (début et fin d'heures creuses) plutôt que de coder 21h45 en dur.

#### D.4 Ménage et chaînes de dépendance

| Tâche | Fenêtre | Dépendance |
|---|---|---|
| Poussière | 7 à 8 jours | Déclenche Aspirateur dans les 24h |
| Aspirateur | 2 à 3 jours | Aucune |
| Récurage | 7 à 8 jours | Déclenche Aspirateur dans les 24h |
| Salle de bain | 1 mois | Aucune |
| Litière, nettoyage partiel | 2 jours | Non gelable |
| Litière, changement complet | 4 jours | Non gelable |
| Grand ménage | 1 mois | Nécessite une intersection de disponibilités |

Règles importantes :

- **Anti-doublon sur les dépendances** : si une occurrence d'aspirateur est déjà planifiée dans la fenêtre de 24 heures suivant la poussière, on la réutilise en la repositionnant après, au lieu d'en créer une deuxième.
- **Ordre imposé** : l'aspirateur déclenché par une dépendance ne peut pas être placé avant sa tâche source.
- **Litière non gelable** : c'est la seule catégorie qui reste due même en statut `MALADE`. En statut `ABSENT` de Thomas, elle est réassignée à Lorette si elle est présente. Si les deux sont absents, elle est reportée avec une alerte explicite au retour.
- **Grand ménage** : nécessite une recherche d'intersection de disponibilités entre les deux utilisateurs, sur une plage d'au moins 3 heures un après-midi. S'il n'existe aucune intersection sur le mois, notifier plutôt que de planifier n'importe quoi.

#### D.5 Cycle du linge

1. Machine lancée après 21h45.
2. Notification de fin de cycle.
3. Étendage validé par Thomas ou Lorette.
4. À J+1 ou J+2 au soir, génération de l'occurrence "Plier et ranger le linge", assignée exclusivement à Lorette.
5. Si l'occurrence est refusée ou non validée après escalade complète, elle est réassignée à Thomas avec une notification neutre. Une tâche qui reste due indéfiniment sur une seule personne finit par pourrir l'usage de l'outil, et un fallback poli vaut mieux qu'un bras de fer automatisé.

---

### 7.5 Module E : statuts globaux et dette de tâches

#### E.1 Effets par statut

| Statut | Sport | Ménage | Litière | Machines | Trajets |
|---|---|---|---|---|---|
| `ACTIF` | Normal | Normal | Normal | Normal | Normal |
| `MALADE` | Gelé | Reporté | Maintenu ou réassigné | Maintenu | Suspendu |
| `ABSENT` (Thomas) | Gelé | Gelé pour lui | Réassigné à Lorette | Gelés pour lui | En cours |

Ces effets sont des lignes de la table `regle_statut`, pas du code.

#### E.2 Entrée et sortie de statut

- Un statut peut être déclaré sans date de fin. Le retour à `ACTIF` est alors manuel.
- L'entrée en statut déclenche une réplanification immédiate.
- La sortie déclenche le traitement de la dette.

#### E.3 Traitement de la dette

À la sortie d'un statut :

1. Les occurrences gelées dont l'échéance est passée sont recréées en `RATTRAPAGE`.
2. Le rattrapage est étalé : maximum 2 tâches de rattrapage par jour, pour ne pas produire une journée de retour insurmontable.
3. Les occurrences de bonus (P5) gelées sont abandonnées, pas rattrapées.
4. Les récurrences repartent de la date de validation réelle, jamais de la date théorique.
5. Un récapitulatif est notifié : "Retour à la normale, 4 tâches à rattraper sur 3 jours."

---

### 7.6 Module F : notifications, validation et escalade

#### F.1 Principes

- Aucun horaire strict pour les tâches de journée, uniquement des rappels.
- Une notification doit toujours permettre d'agir : valider, reporter, refuser.
- Le canal principal porte des boutons d'action. C'est ce qui décide de l'adoption réelle : si valider une tâche demande d'ouvrir une application, tu ne le feras pas.

#### F.2 Niveaux d'escalade

| Niveau | Déclenchement | Fréquence |
|---|---|---|
| 1, information | Au matin du jour prévu | 1 fois |
| 2, rappel | Au créneau prévu | 1 fois |
| 3, échéance | À l'heure limite du soir | 1 fois |
| 4, insistance | 30 minutes après le niveau 3 | Toutes les 20 minutes |
| 5, blocage | Après 5 relances de niveau 4 | Arrêt, report d'office au lendemain avec marquage "en retard" |

#### F.3 Garde-fous

- **Heures de silence** : aucune notification entre 23h30 et 7h30, sauf alerte critique de stock.
- Nombre maximum de notifications par jour et par utilisateur, paramétrable.
- Le niveau 4 ne s'applique qu'aux priorités P1 à P3. Faire vibrer un téléphone toutes les 20 minutes pour un dépoussiérage garantit que les notifications seront coupées dans la semaine.
- Regroupement : plusieurs tâches dues le même soir donnent une seule notification avec une liste.

#### F.4 Validation

- Validation par bouton dans la notification, ou par appel direct de l'endpoint.
- Validation rétroactive possible : "je l'ai fait hier soir", avec choix de la date réelle.
- La date de validation réelle est ce qui alimente le recalcul de la prochaine occurrence.

---

### 7.7 Module G : suivi du travail et rémunération

- Stockage des shifts prévisionnels et des pointages réels.
- Calcul du volume horaire hebdomadaire et mensuel.
- Comparaison entre prévu et pointé, avec alerte sur les écarts.
- Estimation du brut.

Avertissement important : la v1 parlait d'un "calcul simple". En pratique, une estimation qui ignore les majorations de nuit, les dimanches et jours fériés, et le régime des heures complémentaires sur un contrat à temps partiel, divergera du bulletin de paie et perdra toute crédibilité.

Deux options honnêtes :

1. **Estimation assumée** : taux horaire unique, affichage explicite "estimation hors majorations". Simple et utile pour vérifier un volume d'heures.
2. **Calcul détaillé** : paramétrage des plages de majoration et du seuil d'heures complémentaires. Plus juste, plus long.

Recommandation : option 1 au lot 5, option 2 seulement si l'écart constaté te gêne.

---

## 8. Interfaces exposées

### 8.1 Endpoints principaux

```
Authentification
  POST   /auth/login
  POST   /auth/refresh

Planning
  GET    /planning?debut=&fin=&utilisateur=
  POST   /planning/replanifier
  GET    /planning/{id}/decisions

Tâches
  GET    /taches/definitions
  POST   /taches/definitions
  PATCH  /taches/definitions/{id}
  GET    /taches/occurrences?etat=&assigne=
  POST   /taches/occurrences/{id}/valider
  POST   /taches/occurrences/{id}/reporter
  POST   /taches/occurrences/{id}/refuser
  POST   /taches/occurrences (creation manuelle, forcage)

Contraintes
  GET    /occupations?debut=&fin=
  POST   /occupations (saisie manuelle)
  POST   /sources/{code}/collecter (forcage)
  GET    /sources/sante

Statuts
  GET    /statuts/courant
  POST   /statuts (declaration)
  POST   /statuts/{id}/terminer

Stock
  GET    /stock/etat
  GET    /stock/projection
  POST   /stock/unites/{id}/etat

Deplacements
  GET    /trajets
  POST   /trajets/{id}/confirmer
  POST   /trajets (saisie manuelle)

Sport
  GET    /sport/quota
  POST   /sport/seances/{id}/duo

Travail
  GET    /travail/shifts
  GET    /travail/synthese?mois=

Systeme
  GET    /sante
  GET    /journal?entite=&depuis=
```

### 8.2 Export calendrier

Un flux ICS en lecture seule, par utilisateur, protégé par un jeton dans l'URL. Il permet d'afficher le planning dans n'importe quelle application de calendrier, y compris sur téléphone, sans développer de vue dédiée. C'est le meilleur rapport valeur sur effort de tout le projet.

### 8.3 Bot de notification

Le bot n'est pas une interface graphique, c'est un client de l'API. Il doit couvrir à lui seul l'usage quotidien :

- Réception des notifications avec boutons valider, reporter, refuser.
- Commandes de consultation : planning du jour, tâches en retard, état du stock, quota sportif de la semaine.
- Commandes de saisie rapide : déclarer un statut, ajouter un shift, forcer une collecte.

Si cet ensemble suffit à vivre une semaine sans écran, l'API est complète.

### 8.4 Ce que les futurs clients devront pouvoir faire

Cette liste ne décrit pas des écrans à développer ici. Elle sert de test de complétude de l'API : pour chaque ligne, l'endpoint correspondant doit exister et renvoyer tout le nécessaire, sans que le client ait à recalculer quoi que ce soit.

| Besoin client | Ce que l'API doit exposer |
|---|---|
| Vue du jour | Contraintes dures et occurrences du jour, avec leur état et les actions possibles |
| Vue semaine | Planning consolidé sur une plage, en une seule requête |
| Comprendre une décision | Motif de placement de chaque occurrence planifiée |
| Gérer les récurrences | Définitions complètes, historique des validations |
| Suivre le stock | État par unité, date de disponibilité, projection et prochaine lessive |
| Saisie rapide | Shift manuel, emploi du temps de Lorette, déclaration de statut |
| Administration | Santé des sources, journal filtrable, forçage de collecte, paramètres modifiables |

Règle simple : **aucune logique métier dans le client**. Si une future application Angular doit calculer si une tâche est en retard, c'est que l'API aurait dû le dire.

---

## 9. Sécurité et données personnelles

- Authentification par jeton, deux comptes, mots de passe hachés.
- Secrets externes (identifiants de portail, accès IMAP) chiffrés en base avec une clé stockée hors dépôt, injectée par variable d'environnement.
- Aucun secret, aucune donnée réelle dans le dépôt Git. Jeux de données d'exemple anonymisés pour les tests.
- Accès administration uniquement via Tailscale.
- Le système contient des données personnelles des deux utilisateurs : prévoir un export complet et une suppression sur demande. C'est trivial à implémenter au départ et impossible à rajouter proprement plus tard.
- Journal d'accès conservé 90 jours.

---

## 10. Exigences non fonctionnelles

| Exigence | Cible |
|---|---|
| Fuseau horaire | Europe/Paris, avec gestion correcte des changements d'heure. Stockage en UTC, affichage en local. |
| Temps de réplanification | Moins de 5 secondes sur un horizon de 21 jours |
| Disponibilité | Redémarrage automatique des conteneurs, tolérance à une coupure de courant |
| Sauvegarde | Quotidienne, restauration testée au moins une fois avant la mise en production |
| Observabilité | Journaux structurés, endpoint de santé, alerte sur le canal de notification |
| Tests | Couverture prioritaire sur le moteur de planification et la projection de stock, avec des scénarios de non-régression |
| Documentation | README d'installation, schéma d'architecture, description de l'algorithme |

Note sur les tests : ne cherche pas une couverture globale élevée. Concentre les tests sur le moteur et le stock, avec des cas concrets ("semaine à 4 shifts et 2 examens, vérifier qu'une lessive est bien planifiée avant le shift du jeudi"). Ces tests sont aussi la meilleure démonstration de rigueur en entretien.

---

## 11. Plan de réalisation par lots

Chaque lot est livrable et utilisable. La règle est de ne jamais avoir plus d'un lot en cours et de mettre en production à la fin de chaque lot.

### Lot 0 : infrastructure
**Objectif** : une machine prête et une chaîne de déploiement fonctionnelle.
- Montage et installation du mini PC, Debian, Docker, Caddy, Tailscale.
- Dépôt Git, structure du projet, GitHub Actions.
- PostgreSQL en conteneur, sauvegarde automatique et restauration testée.
- Squelette Spring Boot et squelette FastAPI qui répondent sur `/sante`.
**Critère de sortie** : un `git push` déploie les deux services, accessibles en HTTPS.
**Estimation** : 1 semaine.

### Lot 1 : socle métier
**Objectif** : gérer des tâches manuellement, sans aucune automatisation.
- Modèle de données complet des sections 5.1 à 5.3.
- Authentification, deux comptes.
- CRUD des définitions et des occurrences.
- Journal d'événements.
**Critère de sortie** : tu peux créer une tâche, la voir, la valider, et l'historique est correct.
**Estimation** : 2 semaines.

### Lot 2 : calendrier consolidé
**Objectif** : voir toutes les contraintes dures au même endroit.
- Collecteur ICS de l'IDMC avec réconciliation.
- Saisie manuelle des shifts et de l'emploi du temps de Lorette.
- Calcul des disponibilités (passe 1 du moteur).
- Export ICS en lecture seule.
**Critère de sortie** : ton planning universitaire et tes shifts s'affichent dans ton application de calendrier téléphone.
**Estimation** : 2 semaines.

### Lot 3 : moteur de planification v1
**Objectif** : le cœur du système.
- Interface `Planificateur` et implémentation gloutonne.
- Passes 1 à 10 de la section 6.4.
- Priorités, épinglage, backtracking limité, état `NON_PLANIFIABLE`.
- Application aux seules tâches ménagères récurrentes, sans dépendances.
- Tests unitaires sur des scénarios de semaine type.
**Critère de sortie** : le système propose seul un planning de ménage cohérent sur 3 semaines, stable d'un jour à l'autre.
**Estimation** : 3 semaines. C'est le lot le plus difficile, il ne faut pas le raccourcir.

### Lot 4 : notifications et boucle de validation
**Objectif** : rendre le système utilisable au quotidien.
- Canal Telegram ou ntfy, avec boutons d'action.
- Niveaux d'escalade, heures de silence, regroupement.
- Validation, report, refus, validation rétroactive.
- Recalcul des récurrences depuis la validation réelle.
**Critère de sortie** : première semaine complète d'utilisation réelle, uniquement par notifications et commandes du bot.
**Estimation** : 1,5 semaine.

### Lot 5 : intégration McDonald's
**Objectif** : automatiser la source de contrainte la plus lourde à saisir.
- Vérification préalable de la faisabilité (authentification à deux facteurs).
- Collecteur Playwright, gestion de session, chiffrement des identifiants.
- Pointages réels et synthèse d'heures.
- Estimation du brut, option 1.
- Supervision et bascule automatique en mode manuel.
**Critère de sortie** : deux semaines de collecte sans intervention manuelle.
**Estimation** : 2 semaines.

### Lot 6 : stock d'uniforme et machines
**Objectif** : ne plus jamais se retrouver sans uniforme propre.
- Modèle à l'unité avec délais de séchage.
- Projection sur les shifts, calcul d'échéance de lessive.
- Contraintes de lancement après 21h45 et de machine unique.
- Notification de fin de cycle.
- Cycle du linge et assignation du pliage.
**Critère de sortie** : un mois sans rupture, avec des lessives déclenchées au bon moment.
**Estimation** : 2 semaines.

### Lot 7 : sport
**Objectif** : tenir le quota sans y penser.
- Règles de placement, créneaux, trajets, rotation des séances.
- Quota hebdomadaire et mise à l'échelle.
- Collecteur SUAPS et fallback piscine.
- Forçage manuel.
**Critère de sortie** : trois semaines consécutives avec quota atteint sur planification automatique.
**Estimation** : 2 semaines.

### Lot 8 : déplacements
**Objectif** : automatiser les départs vers Saint-Dié.
- Détection de fenêtre de 48 heures.
- Grille horaire de trains, puis API SNCF si nécessaire.
- Boîte mail dédiée et détection de confirmation.
- Statut `ABSENT`, verrouillage de l'agenda, dette au retour.
**Critère de sortie** : un aller-retour complet géré de bout en bout sans saisie.
**Estimation** : 2 semaines.

### Lot 9 : multi-utilisateur
**Objectif** : intégrer Lorette pleinement.
- Assignations, refus, réassignation.
- Table `regle_statut` complète et effets par statut.
- Recherche d'intersection pour le grand ménage.
- Séances de sport en duo.
**Critère de sortie** : Lorette utilise le système d'elle-même pendant deux semaines.
**Estimation** : 2 semaines.

### Lot 10 : consolidation de l'API
**Objectif** : livrer une API propre, documentée et prête à être consommée par un client externe.
- Revue complète des endpoints, cohérence des noms et des formats.
- Spécification OpenAPI complète, avec exemples de requêtes et de réponses.
- Normalisation des erreurs et des codes de retour.
- Endpoints d'administration et de supervision.
- Documentation : README, schéma d'architecture, explication de l'algorithme de planification.
- Jeu de données de démonstration anonymisé, pour pouvoir montrer le projet sans exposer tes vraies données.
**Critère de sortie** : quelqu'un d'autre peut développer un client contre ton API en lisant uniquement la spécification, sans te poser de question.
**Estimation** : 2 semaines.

**Total indicatif** : environ 21 semaines à rythme de projet personnel étudiant. Le système devient réellement utile dès la fin du lot 4, soit environ 9 semaines. C'est le jalon qui compte : à partir de là, chaque lot améliore quelque chose que tu utilises déjà.

### Projet suivant, hors de ce cahier des charges

L'application Angular sera un projet distinct, avec son propre dépôt et son propre cahier des charges. Elle ne consommera que l'API décrite ici. Cette séparation est un atout : deux dépôts propres, un contrat d'interface entre les deux, et une démonstration nette de séparation des responsabilités.

---

## 12. Risques et parades

| Risque | Impact | Parade |
|---|---|---|
| Le scraper McDo casse ou est bloqué | Élevé | Mode de saisie manuelle disponible dès le lot 1, supervision et bascule automatique |
| Le moteur produit un planning irréaliste et tu cesses de l'utiliser | Critique | Motif de décision affiché pour chaque placement, forçage manuel toujours possible, ajustement des paramètres sans redéploiement |
| Le planning change tous les jours | Élevé | Règle d'épinglage de la section 6.5 |
| Sur-ingénierie et abandon | Critique | Lots courts, mise en production à chaque fin de lot, périmètre v1 verrouillé |
| Notifications trop insistantes, désactivation | Élevé | Escalade réservée aux priorités hautes, heures de silence, regroupement |
| Lorette n'adopte pas l'outil | Moyen | Tout se fait par notifications à boutons, aucune application à installer ni compte à gérer |
| Perte de données | Moyen | Sauvegarde quotidienne hors machine, restauration testée |
| Changement d'URL ICS à la rentrée | Faible | Paramétrable en base, pas en dur |

---

## 13. Décisions à trancher avant démarrage

1. Canal de notification : Telegram ou ntfy. (Recommandation : Telegram, pour les boutons de validation.)
2. Le portail McDonald's impose-t-il une authentification à deux facteurs ? Cela conditionne tout le lot 5.
3. L'école de Lorette fournit-elle un flux ICS ?
4. Horaires de train : grille statique ou API SNCF dès le départ ?
5. Plage exacte des heures creuses, si la contrainte de 21h45 en découle.
6. Veux-tu un carnet d'entraînement détaillé (exercices, charges) ou seulement des séances planifiées ?
7. Quelles sont les plages de sommeil à modéliser comme contrainte dure, et faut-il aussi modéliser les repas ?
8. Lorette valide-t-elle ses propres tâches, ou acceptez-vous un mode où l'un peut valider pour l'autre ?
9. Le grand ménage doit-il pouvoir être planifié un matin, ou strictement l'après-midi ?
10. Souhaites-tu rendre le dépôt public ? Si oui, le collecteur McDonald's doit vivre dans un dépôt privé séparé, avec une interface documentée mais une implémentation non publiée.

---

## Annexe A : correspondance v1 vers v2

Rien de la v1 n'a été supprimé. Ce tableau indique où chaque exigence a atterri et ce qui a changé.

| Exigence v1 | Section v2 | Traitement |
|---|---|---|
| Profils Thomas et Lorette | 3 | Repris, avec matrice de permissions |
| Statuts ACTIF, MALADE, LUSSE | 2, 5.1, 7.5 | Repris. `LUSSE` renommé `ABSENT` avec champ lieu, effets rendus configurables en base |
| EDT IDMC par parsing ICS | 7.1 A.2 | Repris, avec réconciliation par UID et collecte toutes les 4h en période de cours |
| Cron nocturne | 6.2 | Repris, complété par des déclenchements événementiels |
| Bouton de forçage manuel | 7.1 A.2, 8.1 | Repris comme endpoint |
| Saisie manuelle EDT Lorette | 7.1 A.3 | Repris, avec récurrences et exceptions |
| Scraping portail McDo | 7.1 A.4 | Repris, avec mode dégradé obligatoire, chiffrement des identifiants et vérification préalable de la double authentification |
| Pointages par quart d'heure | 7.7 | Repris |
| Calcul du salaire brut | 7.7 | Repris, avec avertissement sur les majorations et deux options assumées |
| Détection de 48h libres | 7.2 B.1 | Repris, paramétrable |
| Aller le soir, battement 30 min réductible à 20 | 7.2 B.2 | Repris, avec temps de trajet vers la gare inclus |
| Aller le matin à partir de 9h | 7.2 B.2 | Repris |
| Retour le plus tard possible | 7.2 B.2 | Repris, avec vérification que la séance de sport est réellement plaçable avant d'avancer le retour |
| Lecture Gmail pour valider le billet | 7.1 A.6 | **Modifié** : boîte mail dédiée en IMAP avec transfert automatique, au lieu de l'API Gmail |
| Forçage si billet hors recommandation | 7.2 B.4 | Repris |
| 3 séances de muscu par semaine | 7.3 C.1 | Repris |
| Mise à l'échelle si EDT vide | 7.3 C.1 | Repris, avec seuil de taux d'occupation |
| 1h30 de séance, trou de 3h | 7.3 C.1 | Repris, avec calcul du besoin selon le lieu réel de départ |
| Créneaux 18h et 21h-23h | 7.3 C.1 | Repris, avec condition sur le premier cours du lendemain |
| Une seule séance par jour | 7.3 C.1 | Repris |
| Rotation de 3 types de séances | 7.3 C.2 | Repris, avec reprise de la rotation là où elle s'est arrêtée |
| Renommage manuel de séance | 7.3 C.2 | Repris |
| Forçage de séance hors règles | 7.3 C.3 | Repris, épinglée d'office |
| Matchmaking duo en salle | 7.3 C.4 | Repris, ajustement proposé et jamais automatique |
| Scraping SUAPS et piscine de compensation | 7.3 C.5 | Repris, avec passage en priorité haute si le quota muscu est menacé |
| Stock 3 t-shirts et 2 pantalons | 7.4 D.1 | Repris, modélisé à l'unité |
| Seuil de sécurité jamais à zéro | 7.4 D.2 | Repris, avec projection sur les shifts futurs |
| Déclenchement automatique de la lessive | 7.4 D.2 | Repris. **Ajout majeur** : prise en compte du délai de séchage dans le calcul d'échéance |
| Lessive de blanc hebdomadaire, lave-vaisselle tous les 3-4 jours | 7.4 D.3 | Repris |
| Lancement à partir de 21h45 | 7.4 D.3 | Repris, avec contrainte de machine unique et proposition de paramétrer la plage d'heures creuses |
| Notification de fin de cycle | 7.4 D.3 | Repris |
| Poussière déclenche aspirateur | 7.4 D.4 | Repris, avec règle anti-doublon et ordre imposé |
| Aspirateur tous les 2-3 jours | 7.4 D.4 | Repris |
| Récurage déclenche aspirateur | 7.4 D.4 | Repris |
| Salle de bain mensuelle | 7.4 D.4 | Repris |
| Litière, partiel 2 jours et complet 4 jours | 7.4 D.4 | Repris, marquée non gelable |
| Grand ménage mensuel avec intersection | 7.4 D.4 | Repris, avec notification si aucune intersection n'existe |
| Cycle du linge et pliage assigné à Lorette | 7.4 D.5 | Repris, avec réassignation de secours après escalade complète |
| Pas d'horaires stricts, rappels seulement | 7.6 F.1 | Repris |
| Spam de notifications jusqu'à validation | 7.6 F.2, F.3 | Repris, encadré par des niveaux d'escalade, des heures de silence et une limite d'arrêt |
| Recalcul depuis la date de validation réelle | 6.4 passe 3, 7.6 F.4 | Repris, avec validation rétroactive datée |

---

## Annexe B : cahier des charges v1 (document d'origine)

Conservé intégralement pour référence et pour tracer l'évolution des exigences.

### Objectif du système

Concevoir une API centralisée capable de croiser des emplois du temps hétérogènes (cours, travail salarié), d'automatiser la planification de tâches asynchrones (ménage, sport) et de gérer des stocks flux tendus, avec un système de notifications et d'alertes en temps réel.

### 1. Utilisateurs et Profils

- Profils principaux : Thomas (Administrateur/Système) et Lorette (Utilisatrice standard).
- Statuts globaux :
  - `ACTIF` (Fonctionnement normal).
  - `MALADE` (Disponible pour les deux utilisateurs : gèle immédiatement la planification du sport et décale/réattribue les tâches ménagères).
  - `LUSSE` (Déclenché par les trajets : gèle la présence dans l'appartement pour Thomas, suspend le sport et ses tâches locales, et notifie Lorette de son absence).

### 2. Module A : Synchronisation des Contraintes Dures

- Université de Lorraine (IDMC) :
  - Récupération de l'emploi du temps via parsing de fichier `.ics`.
  - Synchronisation automatique par tâche de fond (Cron job) toutes les nuits.
  - Endpoint de forçage manuel (bouton) pour les changements de salle ou d'horaires de dernière minute (notamment l'après-midi basculé le matin).
  - Saisie Lorette : Renseigne son propre emploi du temps manuellement dans l'attente d'un scraper dédié pour son école.
- McDonald's (Contrat 24h) :
  - Scraping du portail web pour extraire les horaires prévisionnels (sur 2,5 semaines).
  - Récupération des quarts d'heure de pointage réels dans le tableau.
  - Calcul simple et automatisé du salaire brut généré en fonction des horaires réellement pointés.

### 3. Module B : Système Expert de Déplacements (SNCF vers Saint-Dié/Lusse)

- Détection d'opportunité : Si l'algorithme repère 48h consécutives sans IDMC ni McDonald's.
  - Aller (Soir) : Proposition le soir du dernier shift avec un battement de 30 min minimum (réductible à 20 min s'il s'agit du tout dernier train disponible).
  - Aller (Matin) : Si pas de train le soir, proposition du tout premier train disponible le lendemain à partir de 09h00.
  - Retour : Le plus tard possible, sauf si le quota sportif hebdomadaire est en retard (dans ce cas, retour avancé à l'après-midi pour permettre une séance).
- Validation et Forçage :
  - L'API lit les emails (via l'API Gmail) pour détecter l'achat réel du billet, valide le départ et verrouille l'agenda.
  - Forçage manuel : Si un billet est acheté hors des recommandations de l'API (ex: petit trou dans l'agenda), le système le détecte et écrase les règles pour acter le départ.

### 4. Module C : Planification Sportive Intelligente

- Règles de placement (Musculation) :
  - Objectif de base : 3 séances par semaine minimum.
  - Mise à l'échelle : Si l'emploi du temps est très vide, l'API propose automatiquement plus de 3 séances.
  - Durée et Trajet : 1h30 de séance pure. Nécessite un "trou" continu de 3h dans la journée (incluant 15-20 min de trajet domicile ou 30 min depuis la fac).
  - Créneaux alternatifs : 18h00, ou 21h00-23h00 (uniquement si les cours du lendemain commencent à 10h00 ou plus tard).
  - Restriction : 1 seule séance de sport par jour (piscine incluse).
- Contenu et Forçage :
  - Routine : Alternance stricte entre 3 types de séances. Possibilité pour Thomas de renommer manuellement le titre de la séance.
  - Forçage : Thomas peut ajouter manuellement une séance qui ne respecte pas les règles de temps.
- Matchmaking Duo (Salle uniquement) :
  - L'API propose les créneaux de salle à Lorette pour l'informer.
  - Thomas peut ajuster dynamiquement son propre horaire pour l'attendre et y aller avec elle si elle est disponible.
- Piscine (Fallback/Bonus) :
  - Scraping du site du SUAPS/Université pour récupérer les créneaux disponibles.
  - Tentative d'insertion (souvent vers 12h30/14h00). Si le quota de 3 séances de muscu n'est pas atteint, une séance de piscine compense.

### 5. Module D : Logistique de l'Appartement et Tâches Ménagères

- Gestion de stock flux tendu (Uniforme McDo) :
  - Stock total : 3 T-shirts (1 T-shirt = 1 jour), 2 Pantalons (1 Pantalon = 2 jours).
  - Contrainte de sécurité : Le stock disponible ne doit jamais tomber à zéro. Il doit toujours rester au minimum 1 T-shirt ET 1 Pantalon d'avance.
  - Action : Déclenchement automatique de la tâche "Lessive" dès que le seuil de sécurité est menacé par les prochains shifts.
- Machines et Horaires (Contraintes nocturnes) :
  - Lessive vêtement de travail (sur alerte stock) et Lessive de blanc (minimum 1 fois/semaine).
  - Lave-vaisselle (tous les 3-4 jours).
  - Condition stricte : Lancement à partir de 21h45 uniquement.
  - Notification asynchrone pour prévenir de la fin du cycle programmé (pour vider/étendre).
- Chaîne de dépendance du Ménage :
  - Poussière (tous les 7-8 jours) déclenche obligatoirement Aspirateur en suivant.
  - Aspirateur (tous les 2-3 jours indépendamment).
  - Récurage (tous les 7-8 jours) déclenche obligatoirement Aspirateur en suivant.
  - Salle de bain (tous les mois).
  - Litière Sassy : Nettoyage partiel (crottes) tous les 2 jours, changement complet tous les 4 jours.
  - Grand Ménage : Mensuel. L'API doit trouver une intersection de plusieurs heures libres l'après-midi pour Thomas ET Lorette.
- Le cycle du Linge :
  - Thomas (ou Lorette) étend le linge après la machine.
  - À J+1 (le lendemain soir) ou J+2 (le soir d'après), la tâche "Plier et ranger le linge" est générée et assignée exclusivement à Lorette.
- Système de validation et "Spam" :
  - Pas d'horaires stricts pour les tâches en journée, uniquement des rappels par notifications.
  - Si une tâche n'est pas cochée le soir de son échéance : l'API déclenche un spam de notifications jusqu'à validation.
  - Le recalcul de la prochaine occurrence se fait toujours à partir de la date de validation réelle (si fait en retard), pour ne pas fausser le reste du planning.
