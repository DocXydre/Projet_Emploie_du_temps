# Planificateur personnel

[![Tests](https://github.com/DocXydre/Projet_Emploie_du_temps/actions/workflows/tests.yml/badge.svg)](https://github.com/DocXydre/Projet_Emploie_du_temps/actions/workflows/tests.yml)

Un serveur et une application iPhone, HAL, pour un foyer de deux personnes. Le serveur croise les emplois du temps de chacun (cours, calendriers personnels, saisies à la main), en déduit les moments libres, et y place seul les tâches de la maison en les répartissant entre les deux. HAL, un coach sportif construit sur un modèle de langage, écrit le contenu des séances de sport.

Projet personnel, M1 MIAGE (Université de Lorraine).

La spécification complète est dans [`cahier-des-charges-hal.md`](cahier-des-charges-hal.md) : le planning du foyer (partie A), HAL (partie B), l'application (partie C), le foyer et l'administration (partie D), le plan de réalisation (partie E), HAL par MCP et par abonnement (partie F). Il remplace les deux anciens cahiers, que l'historique git garde sous le tag `avant-nettoyage`.

---

## Le problème

Nous sommes deux dans l'appartement. Mes cours changent chaque semaine, j'ai longtemps travaillé en horaires variables chez McDonald's, et je pars régulièrement en train chez ma famille. Le ménage, les lessives et le sport passaient à la trappe. Pas par mauvaise volonté : les caser demande de croiser de tête plusieurs plannings qui bougent tout le temps.

Le système fait ce croisement à notre place. Tout passe par **l'application HAL**, dans le style Liquid Glass d'iOS 26 : quatre onglets, Aujourd'hui, Sport, Maison et Réglages, et l'orbe de HAL au milieu. On y voit sa journée, on coche ce qui est fait, on déclare une absence ou un départ en train. Pour le sport, **HAL** propose les séances, et l'appli lui envoie les données de l'Apple Watch et les séries de musculation. Le planning s'affiche aussi dans **un calendrier** que n'importe quelle application de calendrier peut lire.

Les tâches et le planning se règlent à la main, ou se demandent à HAL, qui ne change rien sans accord. Le bot Telegram du début ne sert plus qu'à l'administrateur du serveur.

---

## Fonctionnalités

| | |
|---|---|
| **Collecte** | Flux iCalendar de l'université et calendriers personnels publiés depuis l'app Calendrier ; un planning de travail se collecte de la même façon. Réconciliation par clé externe, arbitrage des conflits horaires |
| **Placement** | Tâches récurrentes posées dans les creux, un mois d'avance, la semaine en cours figée |
| **Répartition** | Les tâches alternent entre nous deux, et la balance reprend la main quand l'écart se creuse. N'importe qui coche n'importe quoi, l'autre est prévenu. Une tâche cochée attend trente secondes avant de partir : un geste raté se défait |
| **Tâches liées** | Le vidage de la litière vaut ramassage dès le planning ; l'aspirateur se place le jour du récurage ou de la poussière, pour la même personne ; un jour sans cours, les trois forment un bloc |
| **Tâches ajoutées** | Une tâche pour aujourd'hui, entre deux dates, à une heure ou dans une plage, oubliée ou reportée si elle n'est pas faite ; régulière ; ou née d'une autre, comme vider le lave-vaisselle. Des types que le foyer nomme et colore, et des liens posés depuis l'application |
| **Absences** | Partir gèle le ménage ; la charge revient à qui reste, sans rattrapage au retour. Avant un départ à deux : poubelles, lave-vaisselle, litière |
| **Mode allégé** | Pour quelques jours, l'un fait un quart des tâches partagées et l'autre trois quarts. Activé par les deux, il s'annule |
| **Trajets** | Repère les week-ends libres, interroge l'API SNCF, propose des horaires réellement attrapables |
| **Billets** | Lit les confirmations d'achat SNCF en IMAP et déclare l'absence correspondante |
| **Sport** | Les séances se posent dans les heures d'ouverture du lieu, salle, course ou piscine, trajet et battement compris, et une séance peut se proposer à l'autre. HAL en décide le nombre et le contenu, sur quatre semaines |
| **HAL** | Personnel : chaque membre a le sien. Un modèle de langage construit un plan de quatre semaines à partir d'objectifs, propose chaque séance avec ses exercices, suit ce qui est fait et ajuste : un récap chaque soir, une révision le dimanche, une réponse immédiate à un bilan ou à une douleur signalée. Il n'écrit jamais dans une table : il dispose d'une liste fermée d'outils, chacun une fonction SQL, et la base refuse ce qui ne tient pas. Une semaine se valide d'un bouton ; ensuite, il ne la change plus sans accord. Il se met en pause pour des examens ou des vacances |
| **Mémoire de HAL** | Quatre étages, de la semaine en cours à tout ce qui précède les trois derniers mois, résumés seuls chaque nuit. Visible et corrigeable dans Réglages, avec ses anciennes versions |
| **Application HAL** | L'interface de tout le système : planning, maison, sport, santé et HAL. Un accueil fait de widgets qu'on choisit et range. Santé est lue et envoyée toute seule. Une séance de musculation se saisit série par série, sans réseau s'il le faut, avec le poids conseillé par HAL, le record et le record sur dix répétitions sous les yeux, la charge au demi-kilo. Un exercice se change en gardant ses séries, et un exercice absent du catalogue s'ajoute par son nom : HAL le reconnaît. Une course part sur l'Apple Watch, et revient étape par étape, avec sa carte. Widgets iOS et Live Activity du repos |
| **Foyer** | Un administrateur invite par un lien, règle qui peut ajouter et modifier les tâches, passe son rôle. Connexion par pseudo et mot de passe |
| **Calendriers** | Autant d'adresses d'abonnement qu'on veut, chacune montrant certaines personnes et certains contenus |
| **Journal** | Ce qui change, qui l'a déclenché et dans quelle action. Chaque notification porte sa raison, en une phrase, et l'écran Historique remonte le fil |
| **Clients MCP** | HAL est aussi un serveur MCP : Claude Code, Gemini CLI ou Claude Desktop lisent le planning, la maison, les séances, la santé et la mémoire de HAL, avec une clé par client créée dans Réglages. Ils tiennent la mémoire et déposent le résumé de la conversation, que HAL relit dans l'appli. Pour changer le planning, les tâches ou les absences, ils déposent une demande : elle est essayée tout de suite, puis attend l'accord, donné dans l'appli ou depuis la notification |
| **Abonnement plutôt qu'API** | Chacun branche son abonnement Claude dans Réglages : HAL y fait tourner Claude Code sur le serveur, avec la même consigne et ses seuls outils, servis par son propre serveur MCP. Abonnement épuisé, l'API prend le relais avec la clé du compte, jusqu'au plafond du mois, et l'appli dit sous la réponse qui a répondu. Gemini CLI, avec un compte Google, peut entrer dans la même chaîne |
| **Lieux, position et météo** | Chaque lieu a une adresse, dite à HAL, et une mémoire : « à Lusse, je suis chez mes parents ». Les trajets se calculent sur OpenStreetMap depuis là où l'on sera. L'iPhone surveille un cercle de 50 m autour de chaque lieu, sans garder de tracé : HAL demande si l'on reste quand on arrive chez ses parents, si l'on va à sa séance quand on n'est pas à la salle, et comment s'est passée la soirée quand on n'était pas rentré à minuit. Une heure avant une course, des seuils de pluie, de gel, de vent et de chaleur font appeler HAL, qui propose autre chose ; après, la course se lit avec sa météo et la part du parcours face au vent |
| **Sorties** | Notifications par Apple, aux heures que chacun règle, silencieuses la nuit ; flux iCalendar en lecture seule ; bot Telegram pour l'administrateur du serveur |

Ce qui a été retiré ne vit plus dans le dépôt, mais l'historique git le garde sous le tag `avant-nettoyage` : le stock d'uniforme, parti avec la fin du contrat McDonald's ; le bot des membres et la bêta Coach Santé, remplacés par l'application ; les réservations de sport « à déterminer », remplacées par HAL.

---

## Le parti pris technique

**Les règles métier vivent dans PostgreSQL, pas dans le code Python.** C'est le choix structurant du projet, et le sujet de mon cours de conception de systèmes d'information.

L'API est une couche mince : elle appelle des fonctions et expose des vues. Elle ne décide de rien.

| Règle | Où elle est tenue |
|---|---|
| Deux cours ne peuvent pas se chevaucher | `EXCLUDE USING gist` |
| Une occurrence faite ne peut plus être modifiée | Trigger sur colonnes |
| La récurrence repart de la date réelle, pas théorique | Trigger après validation |
| Deux lessives ne tournent pas le même jour | Trigger |
| Deux modes allégés d'une même personne ne se chevauchent pas | `EXCLUDE USING gist` |
| Le grand nettoyage exige que nous soyons libres tous les deux | Intersection de multirange |
| Une tâche est en retard | Vue `v_occurrence` |
| Un exercice interdit par une limitation n'entre dans aucune séance | Fonction `obstacle_sportif` et trigger à la saisie |
| Une différence de charge entre les deux bras est impossible à écrire | Le schéma : une seule colonne de charge |
| Deux séances dures d'un même groupe ne se collent pas | Fonction `obstacle_sportif` |
| HAL ne modifie pas seul une séance validée | Fonction `modifier_seance_proposee` |

L'intérêt est concret : si un script, une saisie manuelle ou l'application iPhone contourne l'API, la base refuse quand même ce qui est incohérent. Et il n'existe qu'une seule définition de « en retard », donc aucun client ne peut en inventer une autre.

**Ce que PostgreSQL apporte ici**, au-delà du stockage :

- `TSTZRANGE` et l'arithmétique de multirange : les disponibilités se calculent en une soustraction d'ensembles, sans boucle ;
- `EXCLUDE USING gist` : le non-chevauchement est une contrainte, pas une vérification applicative ;
- des fonctions PL/pgSQL pour le placement, appelées à l'identique par l'API et par l'ordonnanceur ;
- les outils de HAL : le modèle demande « propose cette séance jeudi », et c'est une fonction SQL qui vérifie le créneau, les limitations et le repos, puis accepte ou rend son motif.

```sql
-- Les moments libres : l'horizon, moins tout ce qui l'occupe.
SELECT unnest(
    tstzmultirange(tstzrange(p_debut, p_fin, '[)'))
    - COALESCE((SELECT range_agg(plage) FROM occupe), '{}'::TSTZMULTIRANGE)
);
```

---

## Architecture

```
   Flux ADE (ICS) ─┐
Calendriers perso ─┼──▶ Collecteurs ──▶ ┌──────────────┐
   Site du SUAPS ──┘                    │              │
                                        │  PostgreSQL  │ ◀── règles métier
   API SNCF (Navitia) ──▶ Trajets ──▶   │              │     contraintes
   Boîte mail (IMAP) ──▶ Billets ──▶    └──────┬───────┘     fonctions
                                               │
                                    ┌──────────┴──────────┐      outils     ┌──────────────┐
   Application HAL ◀──────────────▶ │   FastAPI (mince)   │ ◀─────────────▶ │  API Claude  │
   (tout le quotidien, Santé,       │   module HAL        │                 │  (Anthropic) │
    séries, Apple Watch)            └──────────┬──────────┘                 └──────────────┘
          ▲                                    │
          │ notifications       ┌──────────────┼─────────────────┐
     Apple (APNs) ◀─────────────┘       Flux iCalendar      Bot Telegram
                                       (lecture seule)   (administration)
```

**Pile** : Python 3.12, FastAPI, psycopg 3 sans ORM, PostgreSQL 16, APScheduler, python-telegram-bot, SDK `anthropic`, SDK `mcp` pour le serveur MCP, `claude-agent-sdk` pour passer par l'abonnement. Docker Compose pour l'ensemble, en deux processus de la même image : l'API, qui sert l'appli et les clients MCP, et le travailleur (`api/travailleur.py`), qui fait tourner l'ordonnanceur, le bot d'administration et les appels planifiés de HAL. Un déploiement de l'API ou un appel de HAL de plusieurs minutes ne bloque ainsi pas l'autre, et les erreurs des deux se lisent au même endroit, dans `/erreurs`. L'application est en SwiftUI pour iOS 26, avec HealthKit, WidgetKit, ActivityKit et WorkoutKit, et son projet Xcode se génère par XcodeGen.

**HAL** est du Python dans le processus de l'API pour ce que l'appli lui demande, et dans celui du travailleur pour ce qui est planifié (`api/coach/` : les noms techniques ont gardé « coach »). À chaque appel, il assemble une consigne : un socle du dossier sportif, les paquets utiles au sujet, le contexte et la mémoire du compte, les derniers échanges. Il envoie le tout au modèle avec les outils permis pour ce moment, exécute ceux que le modèle demande, et recommence jusqu'à la réponse. Le dossier sportif est en Markdown dans `coach/dossier/`, un fichier par chapitre : changer une règle sportive, c'est changer du code. Il ne contient rien de personnel, puisque le dépôt est public.

Pas d'ORM : les requêtes sont écrites en SQL, ce qui est cohérent avec l'idée de mettre la logique dans la base. Le schéma, soixante-dix tables rangées par domaine, est dessiné dans [`sql/SCHEMA.md`](sql/SCHEMA.md), généré depuis la base elle-même.

---

## Quelques problèmes rencontrés

Les points qui m'ont demandé le plus de réflexion, et ce que j'en ai tiré. Il y en a d'autres : ils sont tous dans [le cahier des charges](cahier-des-charges-hal.md), sections A.11 et B.11.5.

**Le flux de l'université publie chaque cours deux fois**, avec le même identifiant : une version vide et une version portant la salle et l'enseignant. Réconcilier naïvement par identifiant faisait gagner la dernière lue, donc parfois la version vide, et la salle disparaissait du calendrier. La fusion garde la version la plus informative.

**Une collecte perdait six cours en silence.** Les compteurs affichaient « 80 lues, 51 créées » sans que la différence soit expliquée. J'ai ajouté un invariant : chaque séance lue doit être comptée quelque part, sinon l'écart est signalé. C'est ce contrôle qui a révélé que des chevauchements disparaissaient sans trace.

**Toutes les tâches se posaient le même jour.** Le moteur prenait le premier créneau disponible dans la fenêtre d'échéance, ce qui entassait sept rappels sur un seul soir, et aucun n'était fait. Il choisit maintenant le jour le moins chargé, et à charge égale le plus libre.

**Le gel du planning neutralisait les absences.** Un créneau prévu dans les sept jours ne bougeait plus, ce qui est souhaitable, sauf quand on déclare partir ce week-end-là. Le gel protège un plan encore tenable, pas un plan devenu impossible.

**Une fonction existait en trois versions.** Modifier une fonction voulait dire recopier son corps entier dans une migration nouvelle : `placer_taches` vivait dans trois fichiers, et la version en vigueur était celle du dernier. Corriger un commentaire dans une vieille migration suffisait à réinstaller un placement vieux de quarante migrations, qui appelait une fonction supprimée. Les fonctions, les vues et les déclencheurs ont maintenant un fichier chacun dans `sql/definitions/`, rechargé en entier à chaque passage. Avant de basculer, j'ai vérifié que charger ce dossier sur une base construite par les 47 migrations la laissait identique, objet par objet.

**Chaque « pourquoi ça a fait ça ? » demandait de relire le code.** Pourquoi le lundi est resté en week-end, pourquoi cette tâche a changé de jour, pourquoi la relève des billets n'a rien dit : la réponse était dans la base, mais rien ne la gardait. Un journal note maintenant ce qui change, qui l'a déclenché, et dans quelle action. Un geste dans l'appli, un appel de l'API ou un passage de l'ordonnanceur partagent un numéro d'opération, si bien que la cause se lit à côté de l'effet : « Thomas a déclaré une absence » et « l'aspirateur passe à Lorette » sont deux lignes de la même action. Le placement défait puis repose une soixantaine de tâches à chaque passage ; le journal ne garde que l'état avant et après l'action, et une tâche revenue à sa place ne laisse aucune ligne. Chaque notification en tire sa raison, en une phrase.

**HAL coûtait surtout avant de réfléchir.** Chaque appel commençait par plusieurs passages de lecture (la semaine, la santé, la forme), et chaque passage relisait toute la consigne. Ce que chaque moment lit à coup sûr lui est maintenant donné dans son premier message, plusieurs séances se posent en un seul appel d'outil, et le dossier part en paquets, en résumé ou en entier selon le sujet.

**HAL répondait à 7h30 à des questions déjà réglées.** Le silence de la nuit retenait ses réponses jusqu'au matin. Elles partaient alors toutes ensemble, après d'autres qui les avaient rendues fausses : on aurait dit qu'il avait refait le plan. Pendant une conversation en cours, il répond maintenant tout de suite, même la nuit.

**Les tâches de nuit tournaient deux heures trop tard.** Le conteneur vit en UTC, et l'ordonnanceur était bien configuré en `Europe/Paris`, mais un `CronTrigger` construit à la main fige son fuseau à la construction, et celui du scheduler ne s'applique qu'aux déclencheurs qu'il crée lui-même. Le « report de minuit » se déclenchait donc à 2 h, une fois la date déjà changée. Le fuseau est maintenant passé explicitement à chaque déclencheur.

**Une dizaine de tests échouaient sans rien de cassé.** La configuration lit `.env` dans le dossier où l'on se trouve : lancés depuis le dépôt, les tests y trouvaient l'hôte public, la boîte de courriels et le jeton SNCF, alors qu'ils vérifient justement ce qui se passe sans eux. Ces faux échecs cachaient un vrai bug, une route qui plantait. `outils/tests.sh` les lance maintenant hors du dépôt, avec un environnement vide, sur une base à part.

---

## Démarrage

```bash
cp .env.example .env          # renseigner le mot de passe et les clés d'API
docker compose up -d
./sql/appliquer.sh            # migrations, puis fonctions, vues et déclencheurs
```

Créer les comptes, puis relancer l'API : c'est à son démarrage qu'elle rattache les tâches et les calendriers aux comptes.

```bash
docker exec -i planif-db psql -U planif -d planif <<SQL
INSERT INTO utilisateur (pseudo, nom, role, cle_api) VALUES
  ('thomas',  'Thomas',  'admin',    'CLÉ_A'),
  ('lorette', 'Lorette', 'standard', 'CLÉ_B');
SQL
docker compose restart api
```

Tout le reste se fait dans l'application iPhone HAL : l'administrateur s'y connecte, puis invite les autres membres du foyer depuis Réglages ; une invitation donne un code, et chacun choisit son mot de passe en l'acceptant. Le bot Telegram ne sert plus qu'à l'administrateur du serveur : il s'y relie avec `/demarrer` suivi de sa clé d'API, et reçoit les alertes du serveur.

HAL demande une clé d'API Anthropic dans `.env` ; le nom du modèle est un réglage. Chacun le démarre dans l'appli : profil, limitations, lieux, objectif. L'installation de l'application est dans [`ios/HAL/LISEZMOI.md`](ios/HAL/LISEZMOI.md).

| | |
|---|---|
| Documentation interactive | `http://localhost:8000/documentation` |
| Sonde de santé | `http://localhost:8000/sante` |
| URL d'abonnement au calendrier | `http://localhost:8000/moi/calendrier` |

---

## Déploiement

Le système tourne sur un petit serveur dédié : un portable de récupération sous **Debian 13**, allumé en permanence. C'est ce qui permet aux tâches de nuit de se déclencher pour de bon : un ordonnanceur qui vise 7 h et minuit n'a aucun intérêt sur une machine qui dort.

L'accès distant passe par **Tailscale**, et aucun port n'est ouvert sur la box. `tailscale serve` fournit le HTTPS et son certificat sur le réseau privé : le téléphone s'abonne au calendrier par le nom du tailnet, qui ne change pas d'un réseau Wi-Fi à l'autre, contrairement à une adresse IP locale.

L'application iPhone, elle, n'a pas besoin du client Tailscale. `tailscale funnel` publie l'API sur le port 8443. Chaque route y exige la clé d'API, sauf `/connexion`, l'acceptation d'une invitation et la page de son lien, et les routes d'administration y répondent 403 : l'API reconnaît une requête venue d'Internet à l'en-tête `Tailscale-Funnel-Request` et au port publié (`PORT_FUNNEL`). Le pseudo et le mot de passe, ou Apple, ouvrent une session : une clé par appareil, gardée ensuite dans le trousseau, que se déconnecter révoque sans toucher aux autres. La base ne garde que l'empreinte des clés, et celle du mot de passe en scrypt ; cinq échecs bloquent le compte un quart d'heure.

**Un `git push` suffit à déployer.** Un minuteur systemd exécute `outils/deployer.sh` toutes les deux minutes : il compare `origin/main` au dernier commit déployé avec succès, et s'il y a du nouveau, copie la base avec `pg_dump` (les trente dernières copies restent, dans `~/.local/state/planif/sauvegardes/`, et sans copie rien n'est migré), applique les migrations, recharge les définitions, relance l'API et le travailleur par `docker compose up -d --build api travailleur`, puis attend que l'API réponde sur `/sante`, qui relaie la sonde du travailleur. Un échec est annoncé une fois sur Telegram et réessayé tous les quarts d'heure ; un nouveau commit, lui, part tout de suite.

```
git push  ──▶  GitHub  ◀── (toutes les 2 min)  serveur
                                                  │
          pg_dump ─── migrations ─── définitions ─┴─ compose up --build ─── /sante
```

**Brancher Claude Code.** Dans l'appli, Réglages, Intelligence, « Créer sa clé » donne une clé MCP, montrée une seule fois, et la commande à coller dans le terminal :

```
claude mcp add --transport http hal https://<serveur>.ts.net:8443/mcp --header "X-Cle-Mcp: hal_…"
```

Pour Gemini CLI, la même clé avec `gemini mcp add --scope user --transport http hal <adresse> --header "X-Cle-Mcp: hal_…"`.

`/mcp` passe par le funnel comme les routes de l'appli, derrière sa propre clé : elle n'ouvre que le serveur MCP, se révoque seule, et ne donne jamais la clé de l'appli. L'adresse affichée vient de `HOTE_PUBLIC`.

**Brancher son abonnement.** Toujours dans Réglages, Intelligence : `claude setup-token` sur son ordinateur, puis le jeton collé dans l'appli. Il est essayé une fois, puis gardé chiffré avec `HAL_CLE_CHIFFREMENT` (à tirer une fois, voir `.env.example`). Une clé d'API ajoutée en secours prend le relais quand l'abonnement est épuisé, jusqu'au plafond du mois. Claude Code vient avec le SDK Python : l'image n'a besoin de rien de plus.

**Gemini CLI** se branche de la même façon, dans Réglages, Intelligence : on s'y connecte avec Google une fois sur son ordinateur, puis on colle dans l'appli le contenu de `~/.gemini/oauth_creds.json`, ou une clé de l'API Gemini. L'écran explique chaque étape. Il demande Node.js dans l'image, qui l'a par défaut ; `GEMINI_CLI=0` dans `.env` s'en passe. Ses réponses n'ont pas encore été comparées à celles de Claude sur les scénarios du coach.

**Une copie hors du serveur.** Les copies de `deployer.sh` vivent sur le même disque que la base : elles servent à défaire une migration, pas à survivre à la perte du portable. Chaque jour à 13 h, le Mac demande donc au serveur, par SSH sur Tailscale, un `pg_dump` frais. Il le vérifie avec `pg_restore --list`, en garde trente dans `~/Sauvegardes/planif`, et quatorze dans iCloud, chiffrées par `age` : iCloud ne voit jamais la base en clair. macOS ne laisse pas une tâche de fond lister ni renommer dans iCloud Drive : les copies y occupent donc quatorze emplacements fixes, un par jour sur deux semaines (`planif-samedi-b.dump.age`), et chacune écrase celle d'il y a quatorze jours. Le serveur n'a accès ni au Mac ni à iCloud. Chaque copie s'inscrit au journal du serveur, et le bot prévient après trois jours sans copie. `/etat` dit la date de la dernière.

```bash
brew install age
mkdir -p ~/.config/planif
age-keygen -o ~/.config/planif/age.cle      # affiche la clé publique, age1…
```

La clé privée, `~/.config/planif/age.cle`, se recopie aussi dans un gestionnaire de mots de passe : sans elle, les copies d'iCloud ne se relisent pas, et elle ne doit jamais aller dans iCloud. Puis, dans `~/.config/planif/sauvegardes.env` :

```
PLANIF_SERVEUR=thomas@serveur
PLANIF_AGE_DESTINATAIRE=age1…
```

`./outils/copier_hors_serveur.sh` fait une copie tout de suite, et `./outils/copier_hors_serveur.sh installer` la programme chaque jour. Pour relire une copie d'iCloud : `age -d -i ~/.config/planif/age.cle planif-….dump.age > planif.dump`, puis `pg_restore`.

Le serveur va chercher les mises à jour au lieu d'attendre un webhook : rien à exposer, et un push fait pendant qu'il était éteint est rattrapé au démarrage suivant.

Tout se fait sur `main`, et chaque push part en production. On vérifie donc en local avant :

| Outil | Ce qu'il fait |
|---|---|
| `./outils/tests.sh` | Les tests du serveur, sur une base `planif_test` à part : ils vident la base qu'on leur donne. Ils tournent aussi sur GitHub à chaque push, avec ruff |
| `./outils/fausse_base.sh` | Une base `planif_maquette` toute inventée, aux dates d'aujourd'hui, et l'API dessus : l'application tourne dans le simulateur d'iOS sans aucune donnée réelle, sans notification et sans appel payant à HAL |
| `./outils/local.sh` | Une pile Docker sur une copie de la base, les scénarios de HAL avec le vrai modèle, l'API ouverte au Wi-Fi pour l'iPhone |

---

## Structure

```
sql/                        migrations numérotées : tables, contraintes, données
sql/definitions/            fonctions, vues et déclencheurs, un fichier par fonction
sql/apres/                  rattrapages de données qui appellent une fonction à jour
sql/scenario_test.sql       une semaine type jouée à la main, pour voir les règles à l'œuvre
sql/SCHEMA.md               le schéma de la base, par domaine, généré par outils/schema.py
api/                        FastAPI : routeurs, collecteurs, bot, ordonnanceur, connexion ;
                            main.py pour l'API, travailleur.py pour le travailleur
api/coach/                  HAL : consigne, outils, mémoire, boucle d'appel au modèle,
                            fournisseurs (Claude Code, API, Gemini CLI)
api/serveur_mcp/            HAL en serveur MCP : clés des clients, outils, ressources du dossier
coach/                      le dossier de HAL (un fichier par chapitre), ses paquets, le
                            catalogue d'exercices, sa consigne, ses scénarios
ios/HAL/                    l'application iPhone HAL : planning, maison, sport, santé, HAL,
                            ses widgets et sa Live Activity
outils/                     déploiement, tests, copie hors du serveur, fausse base, pile
                            locale, démarrage d'un compte de HAL, scénarios, schéma de la
                            base, diagnostics d'un flux et de la boîte mail
tests/                      la suite du serveur, sur une vraie base PostgreSQL
.github/workflows/          ruff et les tests à chaque push
```

Les migrations sont numérotées et suivies dans une table `schema_migration` avec l'empreinte de leur contenu. Un fichier modifié est rejoué s'il se déclare idempotent et si aucune migration plus récente n'a repris ce qu'il définit ; sinon le script le signale et demande une migration nouvelle. `./sql/appliquer.sh --adopter FICHIER` prend acte d'une retouche sans SQL, un commentaire corrigé par exemple, sans rien rejouer.

Les fonctions, les vues et les déclencheurs ne vivent plus dans les migrations mais dans `sql/definitions/`, que le script recharge à chaque passage : pour changer une fonction, on modifie son fichier. Les règles tiennent en une page, dans `sql/definitions/LISEZMOI.md`.

---

## Ce que le projet ne fait pas

- **Il n'achète pas les billets de train.** Il propose des horaires et gèle le ménage en conséquence ; l'achat reste manuel.
- **Il ne devine pas les fermetures de la piscine.** Les créneaux hebdomadaires sont relevés automatiquement sur le site du SUAPS, mais les vacances universitaires et les jours fériés se déclarent à la main dans une table dédiée.
- **Il est prévu pour un foyer de deux personnes.** Le modèle accueille d'autres foyers, mais les règles du ménage sont écrites pour deux. L'authentification par clé d'API en en-tête, obtenue une fois par mot de passe, suffit à cette échelle.
- **L'administration n'est pas publique.** Les routes de l'application passent par `tailscale funnel`, derrière la clé ; celles de l'administrateur du serveur ne répondent que sur le réseau privé. C'est voulu pour des données personnelles.
- **HAL ne fait pas de médecine.** Ni questionnaire de santé, ni diagnostic. Il ne parle de médecin que pour une douleur dans la poitrine ou un malaise, et en une phrase pour un complément qui le demande.
- **HAL ne dépense pas sans limite.** L'API n'est qu'un secours de l'abonnement, plafonnée par mois et par compte (10 $ par défaut). Chaque appel garde ses tokens, et `/hal`, dans le bot d'administration, dit ce qu'a coûté la semaine.

---

## Suite

Les quinze lots du plan de réalisation sont faits, et l'application a été reprise écran par écran sur la maquette. Restent :

- côté API, trois manques de l'appli : « Voir plus tard » sur un conflit de cours, qui doit revenir une semaine avant (COL-23) ; une tâche faite en plus qui n'existe pas encore (EXE-17) ; « Je m'en charge » sur une tâche en retard ;
- vérifier sur un vrai iPhone ce que le simulateur ne montre pas : les widgets iOS, l'écran verrouillé, la Live Activity, l'envoi d'une course à la montre ;
- deux semaines d'usage réel à deux, sans le bot (lot 10) ;
- la partie F du cahier des charges est construite (lots 12 à 15). Avant de s'y fier : rejouer les scénarios du coach avec le vrai modèle, par Claude Code et par Gemini CLI, puisque la consigne parle maintenant des demandes ; compiler l'appli, où l'écran Demandes et les actions de la notification n'ont pas encore tourné ; construire l'image avec `GEMINI_CLI=1`.
