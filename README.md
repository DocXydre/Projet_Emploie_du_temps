# Planificateur personnel

API qui croise les emplois du temps de deux personnes (cours, travail, calendriers personnels), en déduit les moments libres, et y place seule les tâches récurrentes : ménage, lessives, séances de sport. Un coach sportif, construit sur un modèle de langage, en écrit le contenu.

Projet personnel, M1 MIAGE (Université de Lorraine).

Spécification complète, en deux cahiers des charges :

- [`cahier-des-charges.md`](cahier-des-charges.md) : le planning, la collecte, les tâches, les trajets, le bot, la connexion ;
- [`cahier-des-charges-coach.md`](cahier-des-charges-coach.md) : le coach sportif et l'application iPhone.

---

## Le problème

Nous sommes deux dans l'appartement. Mes cours changent chaque semaine, j'ai longtemps travaillé en horaires variables chez McDonald's, et je pars régulièrement en train chez ma famille. Le ménage, les lessives et le sport passaient à la trappe. Pas par mauvaise volonté : les caser demande de croiser de tête plusieurs plannings qui bougent tout le temps.

Le système fait ce croisement à notre place et rend deux choses : **un calendrier** à afficher sur le téléphone, et **un bot Telegram** pour cocher ce qui est fait. Pour le sport, **un coach** propose le contenu des séances, et **une application iPhone** lui envoie les données de la montre et les séries de musculation.

```
Aujourd'hui :
  08h00-11h00  Cours : Algo IA, Amphi 201
  17h45-19h15  Sport : Salle de musculation
  21h45-23h30  Lancer le lave-vaisselle

  ○ Passer l'aspirateur (avant de récurer)
  ○ Récurer
  ○ Litière : ramassage
```

---

## Fonctionnalités

| | |
|---|---|
| **Collecte** | Flux iCalendar de l'université et calendriers personnels publiés depuis l'app Calendrier ; un planning de travail se collecte de la même façon. Réconciliation par clé externe, arbitrage des conflits horaires |
| **Placement** | Tâches récurrentes posées dans les creux, un mois d'avance, la semaine en cours figée |
| **Répartition** | Les tâches alternent entre nous deux, et la balance reprend la main quand l'écart se creuse. N'importe qui coche n'importe quoi, l'autre est prévenu |
| **Tâches liées** | Le vidage de la litière vaut ramassage dès le planning ; l'aspirateur se place le jour du récurage ou de la poussière, pour la même personne ; un jour sans cours, les trois forment un bloc |
| **Tâches ajoutées** | Un cycle long ou une chose à faire avant une date, créés depuis Telegram en cinq questions |
| **Absences** | Partir gèle le ménage ; la charge revient à qui reste, sans rattrapage au retour. Avant un départ à deux : poubelles, lave-vaisselle, litière |
| **Mode allégé** | Pour quelques jours, l'un fait un quart des tâches partagées et l'autre trois quarts. Activé par les deux, il s'annule |
| **Trajets** | Repère les week-ends libres, interroge l'API SNCF, propose des horaires réellement attrapables |
| **Billets** | Lit les confirmations d'achat SNCF en IMAP et déclare l'absence correspondante |
| **Sport** | Sans coach, un minimum de séances par semaine, réglable par personne : salle, course ou piscine, dans les heures d'ouverture du lieu, trajet et battement compris. Trois semaines s'organisent d'avance, et une séance peut se proposer à l'autre |
| **Coach** | Activé par compte. Un modèle de langage construit un plan de quatre semaines à partir d'objectifs, propose chaque séance avec ses exercices, suit ce qui est fait et ajuste : une synthèse chaque soir, une révision le dimanche, une réponse immédiate à un bilan ou à une douleur signalée. Il n'écrit jamais dans une table : il dispose d'une liste fermée d'outils, chacun une fonction SQL, et la base refuse ce qui ne tient pas. Une semaine se valide d'un bouton ; ensuite, il ne la change plus sans accord |
| **Mémoire du coach** | Quatre étages, de la semaine en cours à tout ce qui précède les trois derniers mois, résumés seuls chaque nuit. Visible et corrigeable avec `/memoire` |
| **Application iPhone** | Lit l'application Santé (sommeil, fréquence cardiaque, séances de la montre) et l'envoie. Sert aussi à saisir une séance de musculation série par série, avec la dernière fois de chaque exercice sous les yeux. Connexion par pseudo et mot de passe |
| **Calendriers** | Autant d'adresses d'abonnement qu'on veut, chacune montrant certaines personnes et certains contenus |
| **Journal** | Ce qui change, qui l'a déclenché et dans quelle action : `/pourquoi` répond en phrases |
| **Sorties** | Flux iCalendar en lecture seule, bot Telegram avec menu à boutons, silencieux de 23h30 à 7h30 |

Le stock d'uniforme, retiré avec la fin du contrat McDonald's, est rangé dans `anciennes_fonctionnalites/`, avec de quoi le remettre en service.

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
| Le coach ne modifie pas seul une séance validée | Fonction `modifier_seance_proposee` |

L'intérêt est concret : si un script, une saisie manuelle ou l'application iPhone contourne l'API, la base refuse quand même ce qui est incohérent. Et il n'existe qu'une seule définition de « en retard », donc aucun client ne peut en inventer une autre.

**Ce que PostgreSQL apporte ici**, au-delà du stockage :

- `TSTZRANGE` et l'arithmétique de multirange : les disponibilités se calculent en une soustraction d'ensembles, sans boucle ;
- `EXCLUDE USING gist` : le non-chevauchement est une contrainte, pas une vérification applicative ;
- des fonctions PL/pgSQL pour le placement, appelées à l'identique par l'API et par l'ordonnanceur ;
- les outils du coach : le modèle demande « propose cette séance jeudi », et c'est une fonction SQL qui vérifie le créneau, les limitations et le repos, puis accepte ou rend son motif.

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
   Application iPhone ────────────▶ │   FastAPI (mince)   │ ◀─────────────▶ │  API Claude  │
   (Santé, séries)                  │   module coach      │                 │  (Anthropic) │
                                    └──────────┬──────────┘                 └──────────────┘
                                               │
                              ┌────────────────┴────────────────┐
                         Flux iCalendar                  Bot Telegram
                        (lecture seule)              (boutons, validation, coach)
```

**Pile** : Python 3.12, FastAPI, psycopg 3 sans ORM, PostgreSQL 16, APScheduler, python-telegram-bot, SDK `anthropic`. Docker Compose pour l'ensemble. L'application iPhone est en SwiftUI, avec HealthKit, et son projet Xcode se génère par XcodeGen.

**Le coach** est du Python dans le processus de l'API (`api/coach/`). À chaque appel, il assemble une consigne : un socle du dossier sportif, les paquets utiles au sujet, le contexte et la mémoire du compte, les derniers échanges. Il envoie le tout au modèle avec les outils permis pour ce moment, exécute ceux que le modèle demande, et recommence jusqu'à la réponse. Le dossier sportif est en Markdown dans `coach/dossier/`, un fichier par chapitre : changer une règle sportive, c'est changer du code. Il ne contient rien de personnel, puisque le dépôt est public.

Pas d'ORM : les requêtes sont écrites en SQL, ce qui est cohérent avec l'idée de mettre la logique dans la base.

---

## Quelques problèmes rencontrés

Les points qui m'ont demandé le plus de réflexion, et ce que j'en ai tiré. Il y en a d'autres : ils sont tous dans les cahiers des charges, section 11 de [l'un](cahier-des-charges.md) et de [l'autre](cahier-des-charges-coach.md).

**Le flux de l'université publie chaque cours deux fois**, avec le même identifiant : une version vide et une version portant la salle et l'enseignant. Réconcilier naïvement par identifiant faisait gagner la dernière lue, donc parfois la version vide, et la salle disparaissait du calendrier. La fusion garde la version la plus informative.

**Une collecte perdait six cours en silence.** Les compteurs affichaient « 80 lues, 51 créées » sans que la différence soit expliquée. J'ai ajouté un invariant : chaque séance lue doit être comptée quelque part, sinon l'écart est signalé. C'est ce contrôle qui a révélé que des chevauchements disparaissaient sans trace.

**Toutes les tâches se posaient le même jour.** Le moteur prenait le premier créneau disponible dans la fenêtre d'échéance, ce qui entassait sept rappels sur un seul soir, et aucun n'était fait. Il choisit maintenant le jour le moins chargé, et à charge égale le plus libre.

**Le gel du planning neutralisait les absences.** Un créneau prévu dans les sept jours ne bougeait plus, ce qui est souhaitable, sauf quand on déclare partir ce week-end-là. Le gel protège un plan encore tenable, pas un plan devenu impossible.

**Une fonction existait en trois versions.** Modifier une fonction voulait dire recopier son corps entier dans une migration nouvelle : `placer_taches` vivait dans trois fichiers, et la version en vigueur était celle du dernier. Corriger un commentaire dans une vieille migration suffisait à réinstaller un placement vieux de quarante migrations, qui appelait une fonction supprimée. Les fonctions, les vues et les déclencheurs ont maintenant un fichier chacun dans `sql/definitions/`, rechargé en entier à chaque passage. Avant de basculer, j'ai vérifié que charger ce dossier sur une base construite par les 47 migrations la laissait identique, objet par objet.

**Chaque « pourquoi ça a fait ça ? » demandait de relire le code.** Pourquoi le lundi est resté en week-end, pourquoi cette tâche a changé de jour, pourquoi la relève des billets n'a rien dit : la réponse était dans la base, mais rien ne la gardait. Un journal note maintenant ce qui change, qui l'a déclenché, et dans quelle action. Une commande du bot, un appel de l'API ou un passage de l'ordonnanceur partagent un numéro d'opération, si bien que la cause se lit à côté de l'effet : « Thomas a déclaré une absence » et « l'aspirateur passe à Lorette » sont deux lignes de la même action. Le placement défait puis repose une soixantaine de tâches à chaque passage ; le journal ne garde que l'état avant et après l'action, et une tâche revenue à sa place ne laisse aucune ligne. `/pourquoi poubelles` rend le tout en phrases.

**Le coach coûtait surtout avant de réfléchir.** Chaque appel commençait par plusieurs passages de lecture (la semaine, la santé, la forme), et chaque passage relisait toute la consigne. Ce que chaque moment lit à coup sûr lui est maintenant donné dans son premier message, plusieurs séances se posent en un seul appel d'outil, et le dossier part en paquets, en résumé ou en entier selon le sujet.

**Le coach répondait à 7h30 à des questions déjà réglées.** Le silence de la nuit retenait ses réponses jusqu'au matin. Elles partaient alors toutes ensemble, après d'autres qui les avaient rendues fausses : on aurait dit qu'il avait refait le plan. Pendant une conversation en cours, il répond maintenant tout de suite, même la nuit.

**Les tâches de nuit tournaient deux heures trop tard.** Le conteneur vit en UTC, et l'ordonnanceur était bien configuré en `Europe/Paris`, mais un `CronTrigger` construit à la main fige son fuseau à la construction, et celui du scheduler ne s'applique qu'aux déclencheurs qu'il crée lui-même. Le « report de minuit » se déclenchait donc à 2 h, une fois la date déjà changée. Le fuseau est maintenant passé explicitement à chaque déclencheur.

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

Chacun relie ensuite son compte Telegram, avec `/demarrer` suivi de sa clé d'API, puis choisit le mot de passe de l'application iPhone avec `/motdepasse`.

Le coach s'active par compte, avec `POST /coach/activer`. Il demande une clé d'API Anthropic dans `.env` ; le nom du modèle est un réglage. Au premier message, le bot conduit le démarrage : profil, limitations, lieux, objectif. L'installation de l'application iPhone est dans [`ios/CoachSante/LISEZMOI.md`](ios/CoachSante/LISEZMOI.md).

| | |
|---|---|
| Documentation interactive | `http://localhost:8000/documentation` |
| Sonde de santé | `http://localhost:8000/sante` |
| URL d'abonnement au calendrier | `http://localhost:8000/moi/calendrier` |

---

## Déploiement

Le système tourne sur un petit serveur dédié : un portable de récupération sous **Debian 13**, allumé en permanence. C'est ce qui permet aux tâches de nuit de se déclencher pour de bon : un ordonnanceur qui vise 7 h et minuit n'a aucun intérêt sur une machine qui dort.

L'accès distant passe par **Tailscale**, et aucun port n'est ouvert sur la box. `tailscale serve` fournit le HTTPS et son certificat sur le réseau privé : le téléphone s'abonne au calendrier par le nom du tailnet, qui ne change pas d'un réseau Wi-Fi à l'autre, contrairement à une adresse IP locale.

L'application iPhone, elle, n'a pas besoin du client Tailscale. `tailscale funnel` publie l'API sur le port 8443. Chaque route y exige la clé d'API, sauf `/connexion` et l'acceptation d'une invitation, et les routes d'administration y répondent 403 : l'API reconnaît une requête venue d'Internet à l'en-tête `Tailscale-Funnel-Request` et au port publié (`PORT_FUNNEL`). Le pseudo et le mot de passe lui rendent la clé d'API, gardée ensuite dans le trousseau. Le mot de passe n'est stocké que sous forme d'empreinte scrypt, et cinq échecs bloquent le compte un quart d'heure.

**Un `git push` suffit à déployer.** Un minuteur systemd exécute `outils/deployer.sh` toutes les deux minutes : il compare `origin/main` au dernier commit déployé avec succès, et s'il y a du nouveau, applique les migrations, recharge les définitions, relance `docker compose up -d --build`, puis attend que l'API réponde sur `/sante`. Un échec est annoncé une fois sur Telegram et réessayé tous les quarts d'heure ; un nouveau commit, lui, part tout de suite.

```
git push  ──▶  GitHub  ◀── (toutes les 2 min)  serveur
                                                  │
                      migrations ─── définitions ─┴─ compose up --build ─── /sante
```

Le serveur va chercher les mises à jour au lieu d'attendre un webhook : rien à exposer, et un push fait pendant qu'il était éteint est rattrapé au démarrage suivant.

Tout se fait sur `main`, et chaque push part en production. On teste donc en local avant : `outils/local.sh` lance une pile Docker sur une copie de la base, rejoue les scénarios du coach avec le vrai modèle et ouvre l'API au Wi-Fi pour l'application.

---

## Structure

```
sql/                        migrations numérotées : tables, contraintes, données
sql/definitions/            fonctions, vues et déclencheurs, un fichier par fonction
sql/apres/                  rattrapages de données qui appellent une fonction à jour
sql/scenario_test.sql       une semaine type jouée à la main, pour voir les règles à l'œuvre
api/                        FastAPI : routeurs, collecteurs, bot, ordonnanceur, connexion
api/coach/                  le coach : consigne, outils, mémoire, boucle d'appel au modèle
coach/                      son dossier (un fichier par chapitre), ses paquets, son catalogue,
                            sa consigne, ses scénarios
ios/CoachSante/             l'application iPhone : Santé, saisie de musculation
outils/                     déploiement, pile locale, démarrage d'un compte du coach,
                            scénarios, diagnostics d'un flux et de la boîte mail
anciennes_fonctionnalites/  ce qui a été retiré, avec de quoi le remettre
```

Les migrations sont numérotées et suivies dans une table `schema_migration` avec l'empreinte de leur contenu. Un fichier modifié est rejoué s'il se déclare idempotent et si aucune migration plus récente n'a repris ce qu'il définit ; sinon le script le signale et demande une migration nouvelle. `./sql/appliquer.sh --adopter FICHIER` prend acte d'une retouche sans SQL, un commentaire corrigé par exemple, sans rien rejouer.

Les fonctions, les vues et les déclencheurs ne vivent plus dans les migrations mais dans `sql/definitions/`, que le script recharge à chaque passage : pour changer une fonction, on modifie son fichier. Les règles tiennent en une page, dans `sql/definitions/LISEZMOI.md`.

---

## Ce que le projet ne fait pas

- **Il n'achète pas les billets de train.** Il propose des horaires et gèle le ménage en conséquence ; l'achat reste manuel.
- **Il ne devine pas les fermetures de la piscine.** Les créneaux hebdomadaires sont relevés automatiquement sur le site du SUAPS, mais les vacances universitaires et les jours fériés se déclarent à la main dans une table dédiée.
- **Il est prévu pour deux utilisateurs.** L'authentification par clé d'API en en-tête, obtenue une fois par mot de passe, suffit à cette échelle et ne conviendrait pas au-delà.
- **L'administration n'est pas publique.** Les routes de l'application passent par `tailscale funnel`, derrière la clé ; celles de l'administrateur du serveur ne répondent que sur le réseau privé. C'est voulu pour des données personnelles.
- **Le coach ne fait pas de médecine.** Ni questionnaire de santé, ni diagnostic. Il ne parle de médecin que pour une douleur dans la poitrine ou un malaise, et en une phrase pour un complément qui le demande.
- **Il n'a pas de plafond de dépense.** Chaque appel au modèle garde ses tokens, et `/coach` dit ce qu'a coûté la semaine.

---

## Suite

- Garder les séries saisies sans réseau dans l'application, et les envoyer quand il revient.
- Afficher dans l'application la semaine du coach, ses ajustements et leurs boutons, qui ne passent aujourd'hui que par le bot.
- Retirer pour de bon les réservations de sport « à déterminer », que le coach a remplacées (cahier du coach, section 10.3).
