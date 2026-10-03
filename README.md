# Planificateur personnel

API qui croise des emplois du temps — cours, shifts McDonald's, calendriers personnels — en déduit les moments libres, et y place seule les tâches récurrentes : ménage, lessives, séances de sport.

Projet personnel, M1 MIAGE (Université de Lorraine).
Spécification complète : [`cahier-des-charges.md`](cahier-des-charges.md).

---

## Le problème

Je travaille en horaires variables au McDonald's, j'ai des cours qui changent chaque semaine, et je pars régulièrement en train chez ma famille. Le ménage, les lessives et le sport passent à la trappe — non par mauvaise volonté, mais parce que les caser demande de croiser mentalement trois plannings qui bougent tout le temps.

Le système fait ce croisement à ma place et rend deux choses : **un calendrier** à afficher sur le téléphone, et **un bot Telegram** pour cocher ce qui est fait.

```
Aujourd'hui :
  08h00–11h00  Cours : Algo IA — Amphi 201
  11h55–13h05  Sport : Piscine du SUAPS
  17h00–23h00  Travail : Shift McDonald's

  ○ Passer l'aspirateur
  ○ Ramasser la litière
```

---

## Le parti pris technique

**Les règles métier vivent dans PostgreSQL, pas dans le code Python.** C'est le choix structurant du projet, et le sujet de mon cours de conception de systèmes d'information.

L'API est une couche mince : elle appelle des fonctions et expose des vues. Elle ne décide de rien.

| Règle | Où elle est tenue |
|---|---|
| Deux cours ne peuvent pas se chevaucher | `EXCLUDE USING gist` |
| Une occurrence faite ne peut plus être modifiée | Trigger sur colonnes |
| La récurrence repart de la date réelle, pas théorique | Trigger après validation |
| Le linge lavé n'est pas portable tout de suite | Trigger + vue |
| Le grand nettoyage exige que nous soyons libres tous les deux | Intersection de multirange |
| Une tâche est en retard | Vue `v_occurrence` |

L'intérêt est concret : si un script, une saisie manuelle ou un futur front-end contourne l'API, la base refuse quand même ce qui est incohérent. Et il n'existe qu'une seule définition de « en retard », donc aucun client ne peut en inventer une autre.

**Ce que PostgreSQL apporte ici**, au-delà du stockage :

- `TSTZRANGE` et l'arithmétique de multirange — les disponibilités se calculent en une soustraction d'ensembles, sans boucle ;
- `EXCLUDE USING gist` — le non-chevauchement est une contrainte, pas une vérification applicative ;
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
Flux McDo (ICS) ───┼──▶ Collecteurs ──▶ ┌──────────────┐
Calendriers perso ─┘                    │              │
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

Les points qui m'ont demandé le plus de réflexion, et ce que j'en ai tiré.

**Le flux de l'université publie chaque cours deux fois**, avec le même identifiant : une version vide et une version portant la salle et l'enseignant. Réconcilier naïvement par identifiant faisait gagner la dernière lue — donc parfois la version vide, et la salle disparaissait du calendrier. La fusion garde la version la plus informative.

**Une collecte perdait six cours en silence.** Les compteurs affichaient « 80 lues, 51 créées » sans que la différence soit expliquée. J'ai ajouté un invariant : chaque séance lue doit être comptée quelque part, sinon l'écart est signalé. C'est ce contrôle qui a révélé que des chevauchements disparaissaient sans trace.

**Toutes les tâches se posaient le même jour.** Le moteur prenait le premier créneau disponible dans la fenêtre d'échéance, ce qui entassait sept rappels sur un seul soir — donc aucun n'était fait. Il choisit maintenant le jour le moins chargé, et à charge égale le plus libre.

**Le gel du planning neutralisait les absences.** Un créneau prévu dans les sept jours ne bougeait plus, ce qui est souhaitable — sauf quand on déclare partir ce week-end-là. Le gel protège un plan encore tenable, pas un plan devenu impossible.

**Une migration corrigée n'atteignait jamais la base.** Le script sautait tout fichier déjà appliqué, même modifié depuis. Il compare désormais une empreinte SHA-256 et rejoue les fichiers qui se déclarent idempotents.

**Rejouer une vieille migration cassait le placement.** Le remède précédent avait son revers. Quinze fonctions sont réécrites d'une migration à l'autre, et le script rejouait un fichier modifié sans rejouer ceux qui l'avaient repris depuis : corriger un commentaire dans `003` réinstallait un `placer_taches` vieux de quarante migrations, qui appelle une fonction supprimée. Un fichier dont une migration plus récente a repris une fonction, une vue ou une contrainte n'est plus rejoué : le script le dit, nomme ce qui a été repris, et ne touche à rien. Chaque migration passe aussi dans une seule transaction, pour qu'un échec au milieu ne laisse pas la base entre deux versions.

**Une fonction existait en trois versions.** C'est la cause du défaut précédent, et le garde-fou ne la supprimait pas. Modifier une fonction voulait dire recopier son corps entier dans une migration nouvelle : `placer_taches` vivait dans trois fichiers, la version en vigueur était celle du dernier, et un `git diff` montrait deux cents lignes recopiées pour trois lignes changées. Les 90 fonctions, les vues et les déclencheurs ont maintenant un fichier chacun dans `sql/definitions/`, rechargé en entier à chaque passage. Avant de basculer, j'ai vérifié que charger ce dossier sur une base construite par les 47 migrations la laisse identique, objet par objet. Une migration récente qui définit encore une fonction est refusée.

**Chaque « pourquoi ça a fait ça ? » demandait de relire le code.** Pourquoi le lundi est resté en week-end, pourquoi cette tâche a changé de jour, pourquoi la relève des billets n'a rien dit : la réponse était dans la base, mais rien ne la gardait. Un journal note maintenant ce qui change, qui l'a déclenché, et dans quelle action. Une commande du bot, un appel de l'API ou un passage de l'ordonnanceur partagent un numéro d'opération, si bien que la cause se lit à côté de l'effet : « Thomas a déclaré une absence » et « l'aspirateur passe à Lorette » sont deux lignes de la même action. Le placement défait puis repose une soixantaine de tâches à chaque passage ; le journal ne garde que l'état avant et après l'action, et une tâche revenue à sa place ne laisse aucune ligne. `/pourquoi poubelles` rend le tout en phrases.

**Un déploiement raté ne se voyait pas.** Le script comparait `HEAD` à `origin/main`, et fusionnait avant d'appliquer les migrations. Si l'une d'elles échouait, la fusion était déjà faite : le passage suivant concluait qu'il n'y avait plus rien à faire, et le serveur restait sur l'ancienne API avec une base à moitié migrée. Le script retient maintenant le dernier commit déployé avec succès, réessaie tout seul, et prévient une fois sur Telegram. Un déploiement ne compte que si l'API répond sur `/sante` après le redémarrage.

**Une collecte muette effaçait deux semaines de planning.** La réconciliation supprime les occupations à venir qui ne sont plus dans le flux — c'est ce qu'il faut faire quand un shift est annulé. Mais un flux qui ne répond plus, ou qui renvoie une page de connexion, produit exactement le même signal : zéro événement. Le relevé des horaires de sport refuse désormais un résultat vide et conserve ce qu'il avait, plutôt que de vider le planning en silence.

**Le bot restait muet après un redémarrage du serveur.** Docker relance les conteneurs au démarrage, mais avant que le DNS soit prêt : la connexion à Telegram échouait sur une erreur de résolution de nom, et le code abandonnait définitivement. L'API répondait normalement, la sonde de santé était au vert, et rien n'arrivait sur le téléphone — le pire genre de panne. La connexion se retente maintenant en tâche de fond, avec un délai qui double jusqu'à cinq minutes.

**Les tâches de nuit tournaient deux heures trop tard.** Le conteneur vit en UTC, et l'ordonnanceur était bien configuré en `Europe/Paris` — mais un `CronTrigger` construit à la main fige son fuseau à la construction, et celui du scheduler ne s'applique qu'aux déclencheurs qu'il crée lui-même. Le « report de minuit » se déclenchait donc à 2 h, une fois la date déjà changée. Le fuseau est maintenant passé explicitement à chaque déclencheur.

---

## Fonctionnalités

| | |
|---|---|
| **Collecte** | Flux iCalendar de l'université et du travail, calendriers personnels publiés depuis l'app Calendrier. Réconciliation par clé externe, arbitrage des conflits horaires |
| **Placement** | Tâches récurrentes posées dans les creux, un mois d'avance, la semaine en cours figée |
| **Tâches liées** | Le vidage de la litière vaut ramassage dès le planning ; l'aspirateur se place le jour du récurage ou de la poussière, pour la même personne ; un jour sans cours, les trois forment un bloc |
| **Tâches ajoutées** | Un cycle long ou une chose à faire avant une date, créés depuis Telegram en cinq questions |
| **Absences** | Partir gèle le ménage ; la charge revient à qui reste, sans rattrapage au retour. Avant un départ à deux : poubelles, lave-vaisselle, litière |
| **Mode allégé** | Pour quelques jours, l'un fait un quart des tâches partagées et l'autre trois quarts. Activé par les deux, il s'annule |
| **Trajets** | Repère les week-ends libres, interroge l'API SNCF, propose des horaires réellement attrapables |
| **Billets** | Lit les confirmations d'achat SNCF en IMAP et déclare l'absence correspondante |
| **Sport** | Trois séances par semaine — piscine, course ou salle — dans les heures d'ouverture du lieu, trajet et battement compris. Les créneaux possibles sont proposés le lundi matin |
| **Journal** | Ce qui change, qui l'a déclenché et dans quelle action : `/pourquoi` répond en phrases |
| **Sorties** | Flux iCalendar en lecture seule, bot Telegram avec menu à boutons |

Le stock d'uniforme, retiré avec la fin du contrat McDonald's, est rangé dans `anciennes_fonctionnalites/`, avec de quoi le remettre en service.

---

## Démarrage

```bash
cp .env.example .env          # renseigner le mot de passe et les clés d'API
docker compose up -d
./sql/appliquer.sh            # applique les migrations manquantes
```

Créer les comptes, puis rejouer les assignations par défaut :

```bash
docker exec -i planif-db psql -U planif -d planif <<SQL
INSERT INTO utilisateur (pseudo, nom, role, cle_api) VALUES
  ('thomas',  'Thomas',  'admin',    'CLÉ_A'),
  ('lorette', 'Lorette', 'standard', 'CLÉ_B');
SQL
./sql/appliquer.sh
```

| | |
|---|---|
| Documentation interactive | `http://localhost:8000/documentation` |
| Sonde de santé | `http://localhost:8000/sante` |
| URL d'abonnement au calendrier | `http://localhost:8000/moi/calendrier` |

---

## Déploiement

Le système tourne sur un petit serveur dédié — un portable de récupération sous **Debian 13**, allumé en permanence. C'est ce qui permet aux tâches de nuit de se déclencher pour de bon : un ordonnanceur qui vise 7 h et minuit n'a aucun intérêt sur une machine qui dort.

L'accès distant passe par **Tailscale** : aucun port n'est ouvert sur Internet, et `tailscale serve` fournit le HTTPS et son certificat. Le téléphone s'abonne au calendrier par le nom du tailnet, qui ne change pas d'un réseau Wi-Fi à l'autre — contrairement à une adresse IP locale.

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
sql/          migrations numérotées : tables, contraintes, données
sql/definitions/   fonctions, vues et déclencheurs, un fichier par fonction
api/          FastAPI — routeurs, collecteurs, bot, ordonnanceur
outils/       script de déploiement, diagnostic IMAP hors Docker
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

Une interface web (Angular) pour remplacer le bot sur les usages qui demandent un écran.
