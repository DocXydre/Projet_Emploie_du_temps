# Planificateur personnel

API qui croise les emplois du temps de deux personnes (cours, travail, calendriers personnels), en déduit les moments libres, et y place seule les tâches récurrentes : ménage, lessives, séances de sport.

Projet personnel, M1 MIAGE (Université de Lorraine).
Spécification complète : [`cahier-des-charges.md`](cahier-des-charges.md).

---

## Le problème

Nous sommes deux dans l'appartement. Mes cours changent chaque semaine, j'ai longtemps travaillé en horaires variables chez McDonald's, et je pars régulièrement en train chez ma famille. Le ménage, les lessives et le sport passaient à la trappe. Pas par mauvaise volonté : les caser demande de croiser de tête plusieurs plannings qui bougent tout le temps.

Le système fait ce croisement à notre place et rend deux choses : **un calendrier** à afficher sur le téléphone, et **un bot Telegram** pour cocher ce qui est fait.

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
| **Sport** | Un minimum de séances par semaine, réglable par personne : salle, course ou piscine, dans les heures d'ouverture du lieu, trajet et battement compris. Trois semaines s'organisent d'avance, et une séance peut se proposer à l'autre |
| **Coach** | En construction sur la branche `coach`, activé par compte. Un modèle de langage construit un plan de quatre semaines à partir d'objectifs, propose chaque séance avec ses exercices, suit ce qui est fait et ajuste. Il n'écrit jamais dans une table : il dispose d'une liste fermée d'outils, chacun une fonction SQL, et la base refuse ce qui ne tient pas. Voir `cahier-des-charges-coach.md` |
| **Calendriers** | Autant d'adresses d'abonnement qu'on veut, chacune montrant certaines personnes et certains contenus |
| **Journal** | Ce qui change, qui l'a déclenché et dans quelle action : `/pourquoi` répond en phrases |
| **Sorties** | Flux iCalendar en lecture seule, bot Telegram avec menu à boutons |

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

L'intérêt est concret : si un script, une saisie manuelle ou la future application contourne l'API, la base refuse quand même ce qui est incohérent. Et il n'existe qu'une seule définition de « en retard », donc aucun client ne peut en inventer une autre.

**Ce que PostgreSQL apporte ici**, au-delà du stockage :

- `TSTZRANGE` et l'arithmétique de multirange : les disponibilités se calculent en une soustraction d'ensembles, sans boucle ;
- `EXCLUDE USING gist` : le non-chevauchement est une contrainte, pas une vérification applicative ;
- des fonctions PL/pgSQL pour le placement, appelées à l'identique par l'API et par l'ordonnanceur.

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
                                    ┌──────────┴──────────┐
                                    │   FastAPI (mince)   │
                                    └──────────┬──────────┘
                                               │
                              ┌────────────────┴────────────────┐
                         Flux iCalendar                  Bot Telegram
                        (lecture seule)              (boutons, validation)
```

**Pile** : Python 3.12, FastAPI, psycopg 3 sans ORM, PostgreSQL 16, APScheduler, python-telegram-bot. Docker Compose pour l'ensemble.

Pas d'ORM : les requêtes sont écrites en SQL, ce qui est cohérent avec l'idée de mettre la logique dans la base.

---

## Quelques problèmes rencontrés

Les points qui m'ont demandé le plus de réflexion, et ce que j'en ai tiré. Il y en a d'autres, sur la collecte et le déploiement : ils sont tous dans le [cahier des charges](cahier-des-charges.md), section 11.

**Le flux de l'université publie chaque cours deux fois**, avec le même identifiant : une version vide et une version portant la salle et l'enseignant. Réconcilier naïvement par identifiant faisait gagner la dernière lue, donc parfois la version vide, et la salle disparaissait du calendrier. La fusion garde la version la plus informative.

**Une collecte perdait six cours en silence.** Les compteurs affichaient « 80 lues, 51 créées » sans que la différence soit expliquée. J'ai ajouté un invariant : chaque séance lue doit être comptée quelque part, sinon l'écart est signalé. C'est ce contrôle qui a révélé que des chevauchements disparaissaient sans trace.

**Toutes les tâches se posaient le même jour.** Le moteur prenait le premier créneau disponible dans la fenêtre d'échéance, ce qui entassait sept rappels sur un seul soir, et aucun n'était fait. Il choisit maintenant le jour le moins chargé, et à charge égale le plus libre.

**Le gel du planning neutralisait les absences.** Un créneau prévu dans les sept jours ne bougeait plus, ce qui est souhaitable, sauf quand on déclare partir ce week-end-là. Le gel protège un plan encore tenable, pas un plan devenu impossible.

**Une fonction existait en trois versions.** Modifier une fonction voulait dire recopier son corps entier dans une migration nouvelle : `placer_taches` vivait dans trois fichiers, et la version en vigueur était celle du dernier. Corriger un commentaire dans une vieille migration suffisait à réinstaller un placement vieux de quarante migrations, qui appelait une fonction supprimée. Les fonctions, les vues et les déclencheurs ont maintenant un fichier chacun dans `sql/definitions/`, rechargé en entier à chaque passage. Avant de basculer, j'ai vérifié que charger ce dossier sur une base construite par les 47 migrations la laissait identique, objet par objet.

**Chaque « pourquoi ça a fait ça ? » demandait de relire le code.** Pourquoi le lundi est resté en week-end, pourquoi cette tâche a changé de jour, pourquoi la relève des billets n'a rien dit : la réponse était dans la base, mais rien ne la gardait. Un journal note maintenant ce qui change, qui l'a déclenché, et dans quelle action. Une commande du bot, un appel de l'API ou un passage de l'ordonnanceur partagent un numéro d'opération, si bien que la cause se lit à côté de l'effet : « Thomas a déclaré une absence » et « l'aspirateur passe à Lorette » sont deux lignes de la même action. Le placement défait puis repose une soixantaine de tâches à chaque passage ; le journal ne garde que l'état avant et après l'action, et une tâche revenue à sa place ne laisse aucune ligne. `/pourquoi poubelles` rend le tout en phrases.

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

Chacun relie ensuite son compte Telegram, avec `/demarrer` suivi de sa clé d'API.

| | |
|---|---|
| Documentation interactive | `http://localhost:8000/documentation` |
| Sonde de santé | `http://localhost:8000/sante` |
| URL d'abonnement au calendrier | `http://localhost:8000/moi/calendrier` |

---

## Déploiement

Le système tourne sur un petit serveur dédié : un portable de récupération sous **Debian 13**, allumé en permanence. C'est ce qui permet aux tâches de nuit de se déclencher pour de bon : un ordonnanceur qui vise 7 h et minuit n'a aucun intérêt sur une machine qui dort.

L'accès distant passe par **Tailscale** : aucun port n'est ouvert sur Internet, et `tailscale serve` fournit le HTTPS et son certificat. Le téléphone s'abonne au calendrier par le nom du tailnet, qui ne change pas d'un réseau Wi-Fi à l'autre, contrairement à une adresse IP locale.

**Un `git push` suffit à déployer.** Un minuteur systemd exécute `outils/deployer.sh` toutes les deux minutes : il compare `origin/main` au dernier commit déployé avec succès, et s'il y a du nouveau, applique les migrations, recharge les définitions, relance `docker compose up -d --build`, puis attend que l'API réponde sur `/sante`. Un échec est annoncé une fois sur Telegram et réessayé tous les quarts d'heure ; un nouveau commit, lui, part tout de suite.

```
git push  ──▶  GitHub  ◀── (toutes les 2 min)  serveur
                                                  │
                      migrations ─── définitions ─┴─ compose up --build ─── /sante
```

Le serveur va chercher les mises à jour au lieu d'attendre un webhook : rien à exposer, et un push fait pendant qu'il était éteint est rattrapé au démarrage suivant.

---

## Structure

```
sql/                        migrations numérotées : tables, contraintes, données
sql/definitions/            fonctions, vues et déclencheurs, un fichier par fonction
api/                        FastAPI : routeurs, collecteurs, bot, ordonnanceur
api/coach/                  le coach : consigne, outils, boucle d'appel au modèle
coach/                      son dossier (un fichier par chapitre), son catalogue, ses scénarios
outils/                     script de déploiement, diagnostic IMAP hors Docker
anciennes_fonctionnalites/  ce qui a été retiré, avec de quoi le remettre
```

Les migrations sont numérotées et suivies dans une table `schema_migration` avec l'empreinte de leur contenu. Un fichier modifié est rejoué s'il se déclare idempotent et si aucune migration plus récente n'a repris ce qu'il définit ; sinon le script le signale et demande une migration nouvelle. `./sql/appliquer.sh --adopter FICHIER` prend acte d'une retouche sans SQL, un commentaire corrigé par exemple, sans rien rejouer.

Les fonctions, les vues et les déclencheurs ne vivent plus dans les migrations mais dans `sql/definitions/`, que le script recharge à chaque passage : pour changer une fonction, on modifie son fichier. Les règles tiennent en une page, dans `sql/definitions/LISEZMOI.md`.

---

## Ce que le projet ne fait pas

- **Il n'achète pas les billets de train.** Il propose des horaires et gèle le ménage en conséquence ; l'achat reste manuel.
- **Il ne devine pas les fermetures de la piscine.** Les créneaux hebdomadaires sont relevés automatiquement sur le site du SUAPS, mais les vacances universitaires et les jours fériés se déclarent à la main dans une table dédiée.
- **Il est prévu pour deux utilisateurs.** L'authentification par clé d'API en en-tête suffit à cette échelle et ne conviendrait pas au-delà.
- **Il n'est pas accessible depuis le web public.** Tout passe par Tailscale : c'est voulu pour des données personnelles, mais il faut le client installé sur chaque appareil.

---

## Suite

Une application iPhone, qui consommera la même API. Aujourd'hui le calendrier sert à voir et le bot à agir : l'application réunira les deux.
