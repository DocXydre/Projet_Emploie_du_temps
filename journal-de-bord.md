# Journal de bord

Ce journal suit l'écart entre l'application et son cahier des charges (`cahier-des-charges-hal.md`), et ce qui a été fait pour le combler. Il sert à Thomas pour voir où en est le projet, et à l'IA qui reprend le travail pour savoir quoi faire, dans quel ordre, et comment.

- Le **cahier des charges** dit ce que l'appli doit être. Il ne raconte pas d'histoire : il se lit seul.
- Le **journal** dit ce qui reste à faire, ce qui est en cours, ce qui est fait, et pourquoi on l'a décidé. C'est ici qu'on écrit au fil de l'eau.

## Sommaire

1. Comment travailler sur ce projet
2. État au 26 octobre 2026
3. Ce qu'il faut faire, par priorité
4. Les avancements souhaités
5. Décisions prises
6. Correspondance des codes de règles
7. Pièges connus
8. Journal des avancements

---

## 1. Comment travailler sur ce projet

Ces consignes valent pour toute session, humaine ou IA.

**Avant de commencer**
1. `git fetch` puis `git log HEAD..origin/main` : Thomas fusionne parfois des branches pendant qu'on travaille. S'il y a du nouveau, `git pull --ff-only`, refaire la fausse base (`./outils/fausse_base.sh`), `xcodegen` dans `ios/HAL`, recompiler.
2. Lire la partie 12 du cahier, « Modifications à apporter », et la section 3 de ce journal : prendre le premier lot de la plus haute priorité qui n'est pas fait, sauf si Thomas demande autre chose.
3. Relire les règles du cahier que le lot touche (leurs codes sont dans la colonne « Règles »).

**Pendant**
- **HAL d'abord, pas d'écran de réglage.** Ce qui se décide en parlant se dit à HAL ; il n'y a pas d'écran pour saisir des règles. Le formulaire des tâches reste tel qu'il est. Quand un choix transforme une demande « IA » en système fixe, le dire à Thomas avant de le faire.
- **Les règles dans la base.** Une règle de gestion est une contrainte, une fonction SQL ou un déclencheur ; l'API reste mince ; SQL écrit à la main ; une fonction par fichier dans `sql/definitions/` ; les migrations ne portent que les tables et les données.
- **Les codes de règles ne changent jamais** et ne se réattribuent pas. Une règle nouvelle prend le premier numéro libre de sa famille (section 6). Le code source cite les codes en commentaire.
- **Tester en local avant de pousser** : chaque push sur `main` est déployé sur le serveur, et chaque push qui touche `ios/` part sur TestFlight.
  - `./outils/tests.sh` : les tests du serveur, dans le conteneur, sur une base `planif_test` à part.
  - `./outils/fausse_base.sh` : la base `planif_maquette`, inventée, aux dates du jour, pour le simulateur.
  - `./outils/local.sh scenarios` : les scénarios de HAL avec le vrai modèle, à rejouer quand une consigne change.
  - L'appli se vérifie dans le simulateur d'iOS sur la fausse base (section 7 pour les pièges).
- **Docker** : ne jamais changer la taille de son disque ni ses ressources ; c'est ce qui avait rempli le disque du Mac.

**Après**
1. Mettre à jour ce journal : l'état du lot (section 3), une entrée datée dans la section 8 (ce qui est fait, comment c'est vérifié, ce qui reste).
2. Si une décision change le cahier, corriger le cahier dans le même commit : la règle, le dictionnaire, la ligne de la partie 12 (la retirer quand elle est faite).
3. `sql/SCHEMA.md` se régénère par `python -m outils.schema` après une migration.
4. Commit : Thomas commite et pousse lui-même. Lui donner les commandes une par une ; le message tient sur une ligne courte, dans son style, sans paragraphe ni mention de Claude, sans ligne « Co-Authored-By » (le dépôt est public, c'est son portfolio).

---

## 2. État au 26 octobre 2026

**Ce qui marche aujourd'hui**

- Le serveur : collecte des calendriers, placement des tâches, rappels, report de minuit, flux iCalendar, journal et Historique, notifications par Apple, bot d'administration, trois conteneurs, déploiement à chaque push.
- Les tâches : un même formulaire pour toutes, types de tâches, liens (Ensuite, Le même jour, Vaut aussi), tâches arrêtées, reprises, effacées ; descriptions tenues par HAL et vérifiées après un changement et chaque lundi.
- HAL : deux HAL (sport de chacun, foyer commun) avec un aiguillage ; gestes par HAL avec « Annuler » cinq secondes ; serveur MCP ; abonnement Claude, API en secours, Gemini CLI ; mémoire en quatre étages.
- Le sport : plan de quatre semaines, séances proposées et validées, séance de musculation hors réseau, séance libre, ajustements, mesures, pause, démarrage dans l'appli, course avec ou sans montre, Santé envoyée en entier.
- Les lieux : adresses, trajets calculés, position par cercles, questions de présence, soirée repérée à minuit, météo des séances dehors et des courses.
- L'appli : Liquid Glass, fond photo, six duos de couleurs et icône assortie, Aujourd'hui composable, widgets iOS, Live Activity, TestFlight interne.

**Ce qui ne correspond pas au cahier** : la partie 12 du cahier en fait la liste complète, numérotée de M1 à M34. La section suivante les range en lots.

---

## 3. Ce qu'il faut faire, par priorité

Chaque lot se termine par quelque chose qu'on peut vérifier. Statuts : **à faire**, **en cours**, **fait** (avec la date).

### Priorité 1 : HAL au quotidien

Ce qui gêne tous les jours : HAL qui se trompe de sujet, des actions qu'on ne peut pas défaire, des messages retenus la nuit.

#### Lot A — Un seul HAL, l'aiguillage par familles · à faire

Modifications : M1, M2, M3, M7, M9 (pour ce lot).

But : un HAL par compte, une conversation, qui reçoit les familles d'outils (maison, sport, les deux) choisies par l'aiguillage ; plus jamais « Maison ou Sport ? » ; un message de sport écrit depuis Maison va au sport.

À faire :
1. Base : `appel_coach.hal` et `echange.hal` deviennent `familles` ; le verrou (index unique partiel) passe à un appel en cours par compte ; `utilisateur.hal_actif` ; retirer `foyer.hal_actif`. Moments : fondre `chat`, `signalement`, `maison` dans `conversation`.
2. `api/aiguillage.py` : ordre élément joint, mots, question en attente, onglet, petit modèle, puis les deux (AIG-1 à AIG-12). `coach/aiguillage.json` : retirer les mots ambigus (« machine », « retour », « depart », « courses », « repos », « plan », « parents », « vacances », « week-end ») ou les déplacer selon leur sens réel.
3. `api/coach/appel.py` : une seule consigne assemblée par blocs selon les familles ; `derniers_echanges()` sans filtre de HAL ; plus de `FoyerInactif` ; outil `ouvrir_famille` qui relance l'appel dans la même opération.
4. Consignes : fusionner `coach/consigne.md` et `coach/consigne_foyer.md` (rôle commun, puis un bloc par famille) ; garder la consigne MCP courte (`coach/consigne_mcp.md`).
5. `api/coach/outils.py` et `api/coach/foyer.py` : les familles commune, maison, sport (section 9.3 du cahier) ; le moment `conversation` a toutes les familles choisies ; retirer `requalifier_en_signalement`.
6. Routes : `POST /hal/message` et `GET /hal/echanges` ; garder un temps les anciennes routes `/coach/question`, `/coach/signalement`, `/coach/changement`, qui appellent la nouvelle.
7. Appli (`HAL/HAL/ConversationHAL.swift`, `PanneauHAL.swift`, `MessagesHAL.swift`) : une conversation, plus de boutons « Maison » / « Sport », plus de réponse en deux blocs.
8. Scénarios : un jeu d'aiguillage (phrases de sport écrites depuis Maison, phrases des deux côtés, « merci ») et rejouer les scénarios de sécurité.

Vérification : sur la fausse base, « j'ai mal au genou, décale ma séance de demain » écrit depuis Maison fait agir sur le sport ; « décale ma séance et la litière » fait les deux dans une réponse ; « merci » n'ouvre aucun choix ; les tests de `tests/test_hal_foyer.py` réécrits passent.

#### Lot B — Actions directes et annulation de deux minutes · à faire

Modifications : M4, M5, M27.

But : ce que HAL ou un client fait se voit tout de suite ; « Annuler » ou « non » le défait pendant deux minutes, en remettant la base dans l'état d'avant.

À faire :
1. Journal : `trg_journal()` garde la ligne complète avant et après pour toutes les tables qu'un geste touche (JRN-1) ; colonnes `evenement.id_action` et `evenement.proprietaire` ; réglage de transaction `planif.action`.
2. Table `action_hal` ; chaque geste de HAL (outils de `api/demandes.py`) s'exécute directement, sous son numéro d'action.
3. `annuler_action()` en SQL : vérifie le délai et que rien n'a changé depuis, rejoue l'état `avant` dans l'ordre inverse, en une transaction ; prévient les membres notifiés. Outil `annuler_action` (famille commune), routes `/hal/actions/{id}/annuler` et `/hal/operations/{operation}/annuler`.
4. Retirer les demandes : table `demande`, `auto_le`, `programmer_les_gestes()`, `executer_les_gestes()` et son passage dans l'ordonnanceur, routes `/demandes`, outils `demander_…` remplacés par les gestes directs dans le catalogue MCP (`api/serveur_mcp/catalogue.py`).
5. Appli : le bloc d'action avec compte à rebours de deux minutes et « Tout annuler » (`PanneauHAL.swift`, composant nouveau) ; « Annuler » dans l'Historique ; retirer l'écran Demandes (`Ecrans/Demandes.swift`), le bandeau d'Aujourd'hui et les actions de notification.

Vérification : « décale l'aspirateur à jeudi » → l'écran Maison change aussitôt ; « Annuler » 90 secondes après remet mardi ; « non » dit à HAL fait de même ; à 2 min 10, refus avec motif ; depuis Claude Code, un geste se fait sans notification d'accord et s'annule depuis l'Historique.

#### Lot C — Plus de silence la nuit, la semaine à tous · à faire

Modifications : M18, M6.

À faire :
1. Retirer `en_silence()`, `silence_debut`, `silence_fin`, leur contrôle dans `regler_heures()`, `api/apple.py`, `api/position.py`, la route `/moi/heures` et l'écran Notifications.
2. `api/coach/verification.py` : le message de la vérification de la semaine est écrit dans la conversation de chaque membre, avec une notification (plus de `deja_affichee`). Retirer le `break` « un seul foyer » au lot E.

Vérification : une notification créée à 1 h part à 1 h ; le lundi, les deux comptes de la fausse base reçoivent le message de la semaine.

### Priorité 2 : le fond

#### Lot D — Les règles dictées à HAL · à faire

Modifications : M10, M11, M12. Règles : RGL-1 à RGL-16.

But : ce qu'on dit d'un calendrier ou d'une tâche devient une règle que le système applique seul ; HAL ne relit plus que ce qu'aucune règle ne sait dire.

À faire :
1. Tables `sorte_regle` et `regle`, remplissage des sortes (section 4.4.1 du cahier), vues `v_regle`, `v_regle_evenement`, `v_regle_jour`.
2. Fonctions : `enregistrer_regle()`, `essayer_regle()`, `compiler_regle()` (rôle en lecture seule, liste de fonctions permises, `statement_timeout` 200 ms), `retirer_regle()`, mise en échec.
3. Collecte (`api/collecteurs/ics.py`, `service.py`) : appliquer les règles de la source ; retirer `langues_suivies`, l'espagnol en dur, `groupe`, `cours_ecartes`. Reprendre la configuration actuelle de chaque source en règles, par une migration de données.
4. Placement et génération (`placer_taches`, `generer_occurrences`) : jours permis par les règles ; `revient = 'regles'` ; occurrences posées par `avant_depart`, `au_retour`, `jours_du_mois` (origine `regle`).
5. HAL : outils `lire_regles`, `ecrire_regle`, `ecrire_regle_sql`, `retirer_regle` ; consigne : règle typée d'abord, SQL ensuite, description en dernier ; vérification de la semaine qui transforme les descriptions en règles.
6. Reprendre les descriptions existantes (poubelles avant un départ, une machine par jour, à deux, eau au retour…) en règles typées quand c'est possible.
7. Appli : le détail d'une tâche et d'un calendrier montre les règles en phrases ; retirer « groupe » et « UE écartées » de `Ecrans/ReglagesPlanning.swift`.
8. Tests : chaque sorte, une règle SQL refusée (point-virgule, autre table, fonction interdite), une règle qui dépasse 200 ms passe en échec.

Vérification : « retire l'espagnol de mon emploi du temps » crée une règle `ecarter_titre`, la collecte suivante n'a plus d'espagnol et le bilan dit combien ; « l'aspirateur jamais le mardi » ne fait plus jamais poser l'aspirateur un mardi, sans appel à HAL ; « les 19 et 23 du mois, un mois sur deux » fait poser les occurrences par le moteur.

#### Lot E — Plusieurs foyers, de une à huit personnes · à faire

Modifications : M13, M14, M15, M16, M17, M23, M24.

À faire :
1. Migration : `id_foyer` sur `tache` et `type_tache`, rempli pour le foyer existant ; types de base par foyer ; `utilisateur.id_foyer` obligatoire ; un foyer neuf pour un compte sans foyer.
2. Toutes les fonctions du ménage par foyer : génération, placement, `choisir_assigne()` (tour de rôle par ancienneté parmi les présents, balance entre le plus et le moins chargé), `est_allege()` et l'allègement au quart de sa part, `seul_ce_jour()`, vérifications (`api/coach/verification.py`, retirer le `break`).
3. `places_libres()` à huit ; `sortir_du_foyer()` crée le foyer neuf et y passe ce qui est au compte (FOY-13) ; accepter une invitation fait quitter l'ancien foyer.
4. Roulement de nuit de la mémoire du foyer.
5. Type de base « Animaux » (libellé par défaut), widget « Type de tâche » au choix.
6. Liste des tâches courantes et démarrage de la maison (DEM-9) : adresse du foyer, puis les tâches à ajouter d'un geste.
7. Appli : textes au pluriel (« les autres » au lieu de « l'autre ») ; foyer d'une personne sans équilibre, « pour qui », allègement, séance à deux (FOY-15).

Vérification : deux foyers dans la fausse base ne voient rien l'un de l'autre ; un foyer de trois répartit en tour de rôle ; quitter un foyer arrive dans un foyer neuf avec le démarrage de la maison ; un compte seul ne voit aucun écran pour les autres.

#### Lot F — Sport : note d'effort, soirées, onglets composables · à faire

Modifications : M8, M25, M26.

À faire :
1. Note d'effort de la montre : la lire dans HealthKit avec la séance (`HAL/Sante/LecteurSante.swift`, `LecteurDetail.swift`), l'envoyer (`activite_sante.effort`), en faire le bilan (`bilan_seance.source_effort = 'montre'`) ; la carte « Effort à donner » seulement sans elle. Vérifier sur un vrai iPhone avec la montre : le simulateur n'a pas cette donnée.
2. Soirées : type d'occupation « soiree », statut « prevue », `soiree.id_occupation` ; « Soirée » dans le « + » ; `noter_soiree` qui pose le créneau ; appel de HAL à l'annonce avec la règle SOI-8 dans la consigne ; pas de deuxième soirée repérée à minuit.
3. Onglets : une disposition par onglet (`HAL/Modules/Disposition.swift`), les cartes de Sport et de Maison en modules (`Ecrans/EcranSport.swift`, `Ecrans/EcranSportMaison.swift`), le crayon et la galerie sur les trois onglets.

Vérification : une course de la montre arrive avec sa note sans rien demander ; « samedi soir je sors » pose le créneau et fait déplacer ou alléger la séance du dimanche matin ; Sport et Maison se réorganisent et gardent leur disposition après relance.

### Priorité 3 : options, nettoyage, ce qui manque

#### Lot G — L'option trains · à faire

Modifications : M28, M29.

1. Table `option_trains` ; reprendre `lieu_famille` et `gare_famille` des comptes, puis les retirer ; écran Réglages, Options, Trains (gares cherchées par leur nom, boîte et mot de passe d'application) ; groupe Options avec la bulle Yanga.
2. Relève des billets par compte (`api/collecteurs/courriel.py`, `api/billets.py`) avec la boîte du compte, chiffrée ; retirer les boîtes de `.env` et `api/config.py`.
3. Propositions de week-end (`api/propositions.py`) et widgets Week-end et Train seulement avec l'option.

Vérification : un compte sans l'option ne voit rien des trains et rien ne tourne pour lui ; avec l'option, un billet reçu dans sa boîte déclare son absence.

#### Lot H — Nettoyage · à faire

Modifications : M30, M31, M32, M33, M34.

1. SUAPS : `api/collecteurs/suaps.py`, `relever_les_horaires` de l'ordonnanceur, ce qui s'y rapporte dans `api/sport.py` et `api/calendrier.py` ; tables `ouverture`, `fermeture` ; colonnes de relevé de `lieu_sport` ; `v_lieu_a_relever`.
2. Lieux par discipline : `discipline_lieu`, `tache_lieu`, routes `/disciplines`, le repli des comptes sans adresse.
3. Code mort : `api/coach/telegram.py` (garder `lire_jour` et `message_d_erreur` dans un module à elles), `depistage`, `note_coach`, `v_journees_travail`, les valeurs d'origine retirées, `preference = 'apres'`, `heure_defaut`, `minutes_domicile`, `minutes_fac`, `mode_collecte = 'scraping'`.
4. Commentaires qui citent des codes retirés (section 6).
5. README et `LISEZMOI` : un foyer de une à huit personnes, un seul HAL, les actions directes, plus de silence, les parties du nouveau cahier.

Vérification : `./outils/tests.sh` passe ; `grep` ne trouve plus `suaps`, `discipline_lieu`, `silence`, `demande` dans le code vivant.

#### Lot I — Ce qui manque encore · à faire

Modifications : M19, M20, M21, M22.

1. « Voir plus tard » côté serveur (`conflit.cache_jusqu_a`, route) ; « Je m'en charge » (route, outil) ; « C'est fait » pour une tâche faite en plus.
2. La répartition de la semaine (REP) : tables `preference`, `attribution`, `charge_semaine`, pénibilités ; calcul du lundi, imprévus, annonce ; bloc « Ma semaine » ; réglage du foyer. À rejouer sur huit semaines réelles : l'écart ne doit pas être pire qu'avec le tour de rôle.

---

## 4. Les avancements souhaités

Ce qui n'est pas encore dans le cahier, ou pas encore décidé. À discuter avec Thomas avant de construire, puis à écrire dans le cahier.

| Idée | Ce qu'on sait | Prochaine étape |
|---|---|---|
| **Le mode Concentration réglé selon l'emploi du temps** | iOS ne laisse pas une appli activer un mode Concentration toute seule. Pistes : une automatisation Raccourcis personnelle (heure, lieu) qui lance un mode, alimentée par une action App Intents de HAL (« quel mode maintenant ? ») ; les filtres de Concentration (Focus Filters), qui font réagir l'appli à un mode mais ne l'activent pas ; des cercles de lieux déjà surveillés (l'école, la salle) qui servent de déclencheur | Étudier sur iOS 26/27 ce que permettent les App Intents et les automatisations sans confirmation ; proposer à Thomas une solution qui ne demande pas de réglage manuel à chaque cours |
| **La piscine du SUAPS** | Le relevé automatique de ses horaires est écarté : Thomas n'y va pas | À revoir plus tard : relevé, ou horaires dans la description du lieu tenue par HAL |
| **Export et suppression des données d'un compte** | Nécessaire avant d'ouvrir le serveur à un autre foyer (RGPD) | À spécifier dans le cahier |
| **Ouvrir le serveur à d'autres foyers** | Aujourd'hui, un compte naît par invitation ou par l'administrateur du serveur | Décider d'une inscription, de limites d'usage par compte |
| **Scénarios de la maison** | Les scénarios rejouables existent pour le sport ; peu pour la maison, l'aiguillage, les règles, l'annulation | Écrire un jeu par famille pendant les lots A, B et D |

---

## 5. Décisions prises

### Le 26 octobre 2026 : réécriture du cahier des charges

Thomas a relu l'ancien cahier (6 200 lignes, sept parties ajoutées au fil des versions, seize annexes d'historique) et a demandé un cahier qui se tienne seul, avec seulement les choix définitifs. Ses décisions :

- Le cahier ne raconte pas les versions : plus de « remplace », de « depuis », de migrations, d'annexes d'anciennes règles. L'historique vit dans git et dans ce journal.
- Séparer clairement l'application (déterministe) et HAL (l'agent) ; l'application tourne autour de HAL, qui croise les emplois du temps, pose et adapte les tâches, coache le sport, lit la santé, cale les séances, s'adapte à tout moment par un appel, et aux particularités physiques.
- Parler davantage des choix d'interface : Liquid Glass, fond personnalisé à tout moment, appli entièrement personnalisable, widgets placés comme on veut.
- **Un seul HAL.** Le Python choisit seulement les familles d'outils (sport ou tâches). L'aiguillage se trompe souvent en prenant du sport pour de la maison : à corriger.
- **Annulation d'une action de HAL : deux minutes.** Dire « non » à HAL défait aussi, par un retour en arrière en SQL.
- **Clients MCP : pas d'accord dans l'appli**, le client est l'utilisateur lui-même.
- **L'appel de début de semaine** passe par l'abonnement de l'administrateur, et tout le foyer reçoit le message.
- HAL vérifie après chaque changement si une tâche est touchée.
- **Plus de « tâches d'origine »** : toutes les tâches sont pareilles.
- **Soirées** : se prévenir à l'avance, ou poser une soirée dans l'emploi du temps (ou la faire poser par HAL) ; HAL évite une séance le lendemain, ou la place le plus tard possible.
- **Plus de silence de nuit** : il bloquait des appels, et le mode Concentration de l'iPhone suffit.
- **Sport et Maison composables** comme Aujourd'hui.
- **Foyer de une à huit personnes** ; un foyer d'une personne n'a rien de ce qui suppose les autres ; quitter un foyer ou en être retiré mène dans un foyer neuf, où l'on redonne ses informations et ses tâches.
- **Note d'effort** pour la musculation et pour la course ; pour la course, c'est la montre qui la donne.
- Retirer la bêta Coach Santé, l'ancien sport, le stock de vêtements, tout ce qui décrit d'anciennes versions.
- **Piscine du SUAPS** écartée, à revoir plus tard.
- **Règles dictées** (choix de Thomas) : HAL choisit une règle typée ; sinon il écrit une règle en SQL ; s'il ne peut pas, ou si elle échoue, il écrit un texte qu'il vérifie lui-même. Cela vaut pour les calendriers (« retire l'espagnol ») comme pour les tâches.
- Retirer les règles qui ne valent que pour Thomas ; garder celles qui valent pour tout le monde.
- **Trains** (choix de Thomas) : gardés pour tous, comme une option qu'on active, avec sa gare de départ et sa gare d'arrivée ; les propositions de week-end y sont liées.
- **Gourde Yanga** (choix de Thomas) : gardée telle quelle, en option.
- **Dictionnaire de données** (choix de Thomas) : gardé en entier dans le cahier.
- **Codes des règles** (choix de Thomas) : gardés ; les trous ne s'expliquent pas dans le cahier, la correspondance est ici.
- Idée à étudier : régler le mode Concentration de l'iPhone selon l'emploi du temps (section 4).

---

## 6. Correspondance des codes de règles

Un code n'est jamais réattribué. Voici ce que sont devenus les codes de l'ancien cahier qui n'existent plus ou ont changé de sens, et les codes nouveaux. Le code source peut encore citer les anciens : les corriger au fil des lots (M33).

**Codes retirés**

| Ancien code | Ce qu'il disait | Ce qui le remplace |
|---|---|---|
| COL-6, COL-17 | L'espagnol retiré en alternance ; les UE au choix écartées par la configuration | Règles de filtre dictées à HAL (RGL) |
| SPT-1, SPT-2, SPT-3 | Heures d'ouverture et fermetures d'un lieu | La description du lieu, tenue par HAL (ADR-16) |
| SPT-8b | L'ordre de préférence des lieux, la piscine en dernier | La description des lieux (LIE-2) |
| SPT-11, SPT-12 | L'heure par défaut d'un lieu ; la séance « après le dernier cours » | Retirées : HAL donne une plage (PLN-5) |
| SPT-14, SPT-15 | Le relevé des horaires du SUAPS | Retirées (section 4 : à revoir) |
| NOT-14 | Les heures de silence | Retirée ; NOT-15 réécrite |
| POS-12 | Pas de question pendant le silence | Retirée |
| COA-25 | La requalification d'un message du chat en signalement | Retirée : tout message a ses outils (COA-5) |
| ADR-18 | Les lieux d'avant, par discipline | Retirée |
| AIG-9 | Deux blocs « Maison » et « Sport » dans une réponse | Retirée : une seule réponse (AIG-5) |
| HDF-1 à HDF-8 | Le HAL du foyer | COA-1 (un HAL par compte), COA-15 (ce qu'il lit des autres), MEM-11 (mémoire du foyer), COA-36 (conversation à soi), COA-34 et COA-35 (qui paie), COA-6 et COA-22 (opération, verrou), VER-9 (HAL injoignable) |
| ACC-1 à ACC-14 | Les demandes des clients, leur accord dans l'appli | ACT-6 (le client agit directement), ACT-2 (annulation) |
| MTA-5 | « Pour qui » réglé par une consigne | RGL-12 |
| MTA-7 | La description montrée dans le détail d'une tâche | MTA-4, RGL-9 |
| FOY-12 | Le passage des deux comptes existants au premier foyer | Retirée (fait une fois) |
| Déjà retirées avant | UNI, TAC-3, TAC-9, TAC-11 à TAC-13, TAC-17, TAC-18, ABS-8, PLA-9, SPT-5, SPT-6, SPT-13, SPT-16, SPT-18 à SPT-23, SPT-26 à SPT-28, SPT-30, CAR-1 à CAR-5, CAR-9, PRO-3, PRO-5, PRO-6 | — |

**Codes nouveaux**

RGL-1 à RGL-16 (règles dictées) ; FOY-13 (foyer neuf en partant), FOY-14 (un compte naît dans un foyer), FOY-15 (foyer d'une personne) ; EXE-18 (je m'en charge) ; SOI-7 à SOI-9 (soirée prévue) ; DEM-9 (démarrage de la maison) ; COA-34 à COA-36 ; MEM-11 ; AIG-11 (l'onglet n'est qu'un indice), AIG-12 (`ouvrir_famille`) ; ACT-8 (« non »), ACT-9 (prévenir les autres membres) ; APP-11, APP-12 ; THM-7 ; WID-9 ; TRJ-12.

**Codes réécrits** (même sujet, sens revu) : COA-1, COA-5, COA-10, COA-22 ; AIG-1 à AIG-8, AIG-10 ; ACT-2 (deux minutes), ACT-6 (clients directs), ACT-7 (affichage) ; FOY-1, FOY-4, FOY-5, FOY-7, FOY-8, FOY-10 ; PLA-12, PLA-15, PLA-16, ABS-3, EXE-16 ; TAC-1, TAC-25, TAC-29 ; NOT-11, NOT-15 ; SAI-4, MON-11 ; TRJ-9, BIL-4, BIL-6, BIL-10, WKD-1 ; VER-3, VER-4, VER-5 ; MTA-1, MTA-2 ; ORB-6 ; WID-4 ; JRN-1, JRN-10 ; CNX-4 ; ADR-16, ADR-17 ; LIE-1, LIE-3 ; SPT-4, SPT-8, SPT-10 ; COL-5, COL-13, COL-16 ; FOU-2, FOU-13, FOU-17 ; MCP-4, MCP-5 ; REP-1 à REP-11 (pour plusieurs membres).

---

## 7. Pièges connus

Ce qui a déjà coûté du temps, pour ne pas le refaire.

**Serveur et base**
- Un flux qui ne répond plus, ou qui renvoie une page de connexion, rend « zéro événement » comme un calendrier vidé : ne jamais supprimer sur un relevé vide (COL-18).
- Le flux de l'université publie chaque cours deux fois, avec le même identifiant : garder la version la plus informative.
- Un titre ou un lieu trop long faisait échouer toute la collecte : couper, jamais refuser (COL-24).
- Un `CronTrigger` construit à la main fige le fuseau du système (UTC dans le conteneur) : passer `Europe/Paris` à chaque déclencheur.
- Une fonction SQL n'a qu'un fichier, dans `sql/definitions/` ; une migration récente qui en définit une est refusée par `sql/appliquer.sh`.
- Les tests lisent `.env` du dossier courant : toujours passer par `./outils/tests.sh`, qui les lance dans le conteneur avec un environnement vide, sur `planif_test`.
- Un test qui compte en heures se trompe au changement d'heure : compter en jours de Paris.
- Chaque relève des calendriers réécrivait les cours à l'identique et remettait toutes les tâches décrites dans la file : ne compter qu'un vrai changement (VER-3).
- Un appel de HAL coûte surtout en écriture de cache : joindre d'office ce que le moment lit à coup sûr (COA-28), poser plusieurs séances en un appel d'outil (COA-29).
- Une réponse coupée par la limite de sortie laisse un appel d'outil tronqué : ne pas l'exécuter (COA-27).
- Le modèle annonçait des séances que la base avait refusées : relire le message contre la base (COA-30).

**Simulateur et appli**
- Un réglage écrit par `simctl … defaults write` n'est pas vu par l'appli qui l'a déjà lu : recompiler avec la valeur voulue.
- Un interrupteur SwiftUI ne réagit pas à un toucher bref de l'outil : le faire glisser.
- Un toucher envoyé pendant que la page défile encore ne fait qu'arrêter le défilement : attendre une à deux secondes.
- La capture peut être en retard d'un geste : ne pas retoucher un bouton à bascule sans vérifier autrement.
- Les cercles de position ne se testent pas sur le simulateur ; les changements importants se testent avec un trajet simulé (`xcrun simctl location … start`).
- L'appli reste quelques secondes sur un écran vide au lancement.
- Pour des captures, recompiler depuis `main` à jour ; garder les vrais noms de la fausse base (ne pas anonymiser).
- Une fusion faite sur GitHub peut laisser du Swift cassé : compiler tout de suite après un `pull`.

---

## 8. Journal des avancements

Une entrée par séance de travail, la plus récente en haut : la date, ce qui a été fait, comment c'est vérifié, ce qui reste.

### 26 octobre 2026 — Cahier des charges réécrit

- `cahier-des-charges-hal.md` réécrit en entier : un seul document qui se tient seul, sans historique, sur le modèle académique (présentation, architecture, acteurs, règles de gestion, application, modèle de données complet, contraintes, opérations, interfaces, exclusions, risques), avec une partie 12 « Modifications à apporter » (M1 à M34).
- Le modèle de données a été tiré du schéma réel de la fausse base (migration 086), puis porté vers la cible : tables à créer, à changer et à retirer marquées.
- Écarts relevés en lisant le code, au-delà des notes de Thomas : la répartition de la semaine n'a jamais été construite ; les tâches et les types n'ont pas de foyer (un seul foyer par serveur) ; la note d'effort de la montre n'est pas lue ; la liste des tâches courantes proposées n'existe pas ; « Voir plus tard », « Je m'en charge » et « tâche faite en plus » manquent côté serveur ; la vérification de la semaine n'envoie son message à personne ; `api/coach/telegram.py` est du code mort.
- Ce journal créé.
- Rien n'est encore changé dans le code : prochaine étape, le lot A.
