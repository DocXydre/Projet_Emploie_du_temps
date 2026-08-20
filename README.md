# Système de planification personnelle

Une API qui croise des emplois du temps hétérogènes — cours à l'IDMC, shifts McDonald's, saisies manuelles — en déduit les moments libres, et y place seule les tâches récurrentes : ménage, litière, lessives.

Le résultat sort en flux iCalendar, à afficher dans n'importe quelle application de calendrier, et en notifications Telegram avec boutons de validation.

Spécification complète : [`cahier-des-charges.md`](cahier-des-charges.md).

## Le parti pris

**Les règles métier vivent dans PostgreSQL**, pas dans le code applicatif. Contraintes `CHECK`, contraintes d'exclusion GiST, vues, fonctions PL/pgSQL et triggers. L'API n'est qu'une couche mince qui appelle et expose.

Concrètement :

| Règle | Où elle vit |
|---|---|
| Deux cours ne peuvent pas se chevaucher | Contrainte d'exclusion `EXCLUDE USING gist` |
| Deux tâches à heure imposée non plus | Contrainte d'exclusion partielle |
| Une occurrence faite ne peut plus bouger | Trigger sur colonnes |
| La récurrence repart de la date réelle | Trigger après validation |
| La poussière déclenche l'aspirateur en 24 h | Trigger, avec règle anti-doublon |
| Le linge lavé n'est pas portable tout de suite | Trigger + vue `v_stock` |
| Le grand nettoyage exige que vous soyez libres tous les deux | `disponibilites_communes`, intersection de multirange |
| Une tâche est en retard | Vue `v_occurrence` |

La base refuse ce qui est incohérent, même si un script ou une saisie manuelle contourne l'API un jour.

## État

Complet et vérifié : 12 tables, 7 vues, 24 fonctions, 6 triggers, 128 tests. Le système collecte, place, répartit, notifie et se pilote au bot.

## Le placement

Trois règles décident de tout.

**Le jour le moins chargé, pas le premier venu.** Une fenêtre d'échéance de trois jours existe pour offrir une marge : la prendre au plus tôt entassait sept tâches le même soir, ce qui garantit qu'aucune n'est faite. À charge égale, la journée la plus libre gagne — sinon un jour occupé de 1h à 23h passerait pour idéal du seul fait qu'aucune tâche n'y est encore prévue.

**Un mois d'avance, une semaine figée.** Les occurrences au-delà de la prochaine sont des prévisions : elles supposent une exécution en fin de fenêtre. Valider une tâche les efface, et la chaîne se refait à partir de la date constatée. Ce qui est prévu dans les sept jours ne bouge plus : on ne s'organise pas autour d'un planning qui se dérobe.

**Certaines tâches n'existent que par enchaînement.** Étendre le linge ne revient pas tous les jours, seulement après une lessive.

## L'absence

Une absence n'est pas une occupation. Être en cours empêche de faire le ménage à ce moment-là ; être parti **dispense** de le faire.

```
/absent 22/08 24/08 Saint-Dié
```

Le planning se refait aussitôt. Pendant l'absence, les tâches sans assigné fixe reviennent à qui reste. Si les deux sont là, à celui qui porte le moins de minutes — la répartition se mesure en temps, pas en nombre de tâches, sinon récurer vaudrait ramasser la litière. Et si l'appartement est vide, elles attendent le retour.

Un jour n'est compté absent que s'il est entièrement couvert : partir vendredi soir laisse le vendredi utilisable.

## Démarrage

```bash
cp .env.example .env
# Renseigner POSTGRES_PASSWORD, puis les deux clés d'API :
LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 48; echo

docker compose up -d
./sql/appliquer.sh
```

Créer les deux comptes, puis rejouer les assignations :

```bash
docker exec -i planif-db psql -U planif -d planif <<SQL
INSERT INTO utilisateur (pseudo, nom, role, cle_api) VALUES
  ('thomas',  'Thomas',  'admin',    'CLÉ_DE_THOMAS'),
  ('lorette', 'Lorette', 'standard', 'CLÉ_DE_LORETTE');
SQL
./sql/appliquer.sh
```

| Point d'entrée | URL |
|---|---|
| Documentation interactive | http://localhost:8000/documentation |
| Santé | http://localhost:8000/sante |
| Flux calendrier | http://localhost:8000/planning.ics?cle=CLÉ |

Sur iPhone : Réglages → Calendrier → Comptes → Ajouter → Autre → Ajouter un abonnement, et coller l'URL du flux.

## Structure

```
sql/
  001_schema.sql        tables, CHECK, contraintes d'exclusion
  002_vues.sql          planning, retards, santé des sources, stock
  003_fonctions.sql     disponibilités, génération, projection, placement
  004_triggers.sql      récurrence, enchaînements, machine unique, stock
  005_donnees.sql       sources, tâches, enchaînements, articles
  006_assignations.sql  qui fait quoi par défaut
  scenario_test.sql     déroulé d'une semaine type, avec assertions
  appliquer.sh
api/
  main.py                  montage, erreurs normalisées, /sante, /planning.ics
  base.py                  pool psycopg, sans ORM
  securite.py              clé d'API
  erreurs.py               SQLSTATE → statut HTTP
  calendrier.py            export iCalendar
  amorcage.py              URL des flux depuis l'environnement
  ordonnanceur.py          collectes, bilan, relance, report
  collecteurs/ics.py       lecture des flux, profils ade et easyatwork
  collecteurs/service.py   collecte et réconciliation, sans HTTP
  routeurs/                planning, tâches, occurrences, contraintes,
                           stock, notifications
tests/                     parcours complet contre un vrai PostgreSQL
  exemple_ade.ics          extraits réels des flux, pièges compris
  exemple_mcdo.ics
```

## Les collecteurs

Les deux sources sont des flux iCalendar, donc un seul collecteur avec deux profils. Pas de scraping, pas de navigateur headless, pas de mot de passe à stocker.

```bash
# On donne l'URL une fois — depuis le bot, en collant simplement le lien
curl -X PATCH -H "X-Cle-Api: $CLE" -H 'Content-Type: application/json' \
     -d '{"url":"https://..."}' localhost:8000/sources/MCDO

curl -X POST -H "X-Cle-Api: $CLE" localhost:8000/sources/MCDO/collecter
```

Les URL ne sont **jamais** dans le dépôt : celle du planning McDonald's contient un jeton d'accès personnel. L'API ne la renvoie pas non plus, seulement `url_renseignee: true`.

| Profil | Source | Produit |
|---|---|---|
| `ade` | Planning universitaire | des occupations `cours` |
| `easyatwork` | Planning McDonald's | des occupations `travail` |

Le flux de l'Université de Lorraine a trois pièges, tous couverts par des tests :

- **Chaque cours apparaît deux fois avec le même UID** : une version vide et une version portant la salle et l'enseignant. Réconcilier naïvement par UID ferait gagner la dernière lue, donc parfois la version vide — la salle disparaîtrait. Le collecteur fusionne par UID en gardant la plus informative.
- **`SALLE A DEFINIR`** n'est pas une salle, et la capacité entre parenthèses n'intéresse personne. `105,Salle 104 (49 Places)` devient `Salle 104`.
- **Le groupe s'écrit `gpe1` ou `gpe 2`**, au choix.

Les filtres sont des données, pas du code — ils vivent dans `source.configuration` :

```json
{
  "profil": "ade",
  "type_occupation": "cours",
  "groupe": 1,
  "alternance": false,
  "langues_suivies": ["anglais", "espagnol"],
  "langues_possibles": ["anglais", "espagnol", "chinois", "allemand"],
  "horizon_jours": 60,
  "historique_jours": 7
}
```

Changer de groupe au second semestre, c'est un `PATCH`, pas un redéploiement. Passer `alternance` à vrai retire l'espagnol. La collecte renvoie toujours le détail de ce qu'elle a écarté : une collecte muette est indébogable.

```json
{"lues": 10, "crees": 6, "mis_a_jour": 0, "annules": 0, "conflits": [],
 "rejets": {"langue non suivie (chinois)": 1, "groupe 2": 2, ...}}
```

## Les conflits horaires

Une source publie parfois deux occupations au même moment. La contrainte d'exclusion en refuse une — et c'est tant mieux, mais il faut décider laquelle garder.

- **Conflit à plus de deux semaines** : rien. L'emploi du temps sera vraisemblablement corrigé avant que ça compte, et faire arbitrer du bruit use la patience.
- **Conflit à moins de deux semaines** : la version rejetée est conservée, une notification part, et la question est posée.

```bash
curl -H "X-Cle-Api: $CLE" localhost:8000/conflits
curl -X POST -H "X-Cle-Api: $CLE" -H 'Content-Type: application/json' \
     -d '{"garder":"nouvelle"}' localhost:8000/conflits/3/resoudre
```

Le choix est mémorisé : garder l'existante écarte durablement l'autre version, et la collecte suivante ne repose pas la même question.

Les fichiers sont rejoués depuis zéro à chaque fois, il n'y a pas encore d'outil de migration. C'est volontaire : tant que la base ne contient pas de données à préserver, `--recreer` est plus simple à comprendre qu'un versionnement.

## Vérifier

```bash
# Le socle SQL
./sql/appliquer.sh --recreer
docker exec -i planif-db psql -U planif -d planif < sql/scenario_test.sql

# L'API, contre la même base
pip install -e ".[dev]"
DB_PORT=5432 pytest -q
```

Les tests d'API reconstruisent le schéma, créent deux comptes et déroulent un parcours complet : authentification, saisie d'occupations, placement, validation, refus, stock, export iCalendar. Ils ne tournent pas sur des simulacres — c'est la base qui refuse un chevauchement ou une revalidation, et le test le constate.

Le scénario monte une semaine type — cinq journées de cours, quatre shifts, du sommeil — puis vérifie :

- qu'un chevauchement de shifts est **refusé par la base** ;
- que les 11 tâches trouvent une place, les rappels sur des journées entières et les machines à 21h45 ;
- qu'aucune tâche à heure imposée n'en chevauche une autre, et qu'aucun jour ne porte deux machines ;
- que valider la poussière crée la suivante **à partir de la date réelle** et repositionne l'aspirateur existant au lieu d'en créer un second ;
- que revalider une tâche close et valider dans le futur sont refusés ;
- que le stock d'uniforme déclenche une lessive, et alerte quand il est trop tard pour que le linge sèche ;
- que le grand nettoyage tombe sur un moment où Thomas **et** Lorette sont libres, et qu'une alerte part s'il n'en existe aucun ;
- qu'une tâche non faite revient le lendemain avec son compteur de relances.

Il tourne dans une transaction annulée à la fin : la base reste intacte.

## Concepts

**Occupation** — une plage subie et non déplaçable. Stockée en `TSTZRANGE`, pas en deux colonnes.

**Tâche** — le modèle récurrent, sans date. Soit un *rappel* (à faire ce jour-là, sans heure), soit *à heure imposée* (les machines, en heures creuses).

**Occurrence** — une exécution concrète. Porte une **fenêtre d'échéance**, pas une date : c'est ce qui laisse au système la marge pour choisir.

**Disponibilités** — l'horizon moins les occupations, moins les créneaux déjà placés. Calculées avec les multirange de PostgreSQL : `range_agg` puis une soustraction, sans boucle.

## Conventions

- Stockage en UTC. Europe/Paris définit ce qu'est « une journée », via `debut_jour()` et `jour_de()`.
- Les énumérations sont des `VARCHAR` contraints par `CHECK`, pas des types `ENUM` : lisibles en SQL et modifiables par migration.
- Une migration appliquée n'est jamais modifiée, une fois qu'il y aura des données à préserver.
- Aucun secret dans le dépôt. Les clés d'API et les identifiants de portail passent par l'environnement.

## L'API en pratique

Elle est mince, et c'est voulu. Valider une tâche, c'est une ligne :

```python
executer("SELECT valider_occurrence(%(id)s, %(acteur)s, %(date)s)", {...})
```

Le reste — créer l'occurrence suivante à partir de la date réelle, déclencher l'aspirateur après la poussière sans doublon, envoyer les t-shirts au séchage — est fait par les triggers. Le jour où une seconde application, un script ou une saisie directe en SQL passe à côté de l'API, les règles tiennent quand même.

Les erreurs ont une seule forme, `{code, message}`, que l'échec vienne de la base ou de l'API :

```json
{"code": "chevauchement", "message": "conflicting key value violates exclusion constraint"}
{"code": "non_reportable", "message": "Cette tâche ne peut pas être repoussée..."}
```

## La boucle quotidienne

C'est elle qui décide si le système sert à quelque chose : sans elle, le planning existe mais personne ne le regarde.

| Quand | Quoi |
|---|---|
| Toutes les heures | Collecte des sources dont la fréquence est écoulée, puis replacement si quelque chose a bougé |
| 07h00 | Placement, puis bilan du jour et des retards. Les créneaux annoncés sont figés |
| 21h00 | Un rappel par tâche du jour non validée — c'est lui qui portera les boutons |
| 00h05 | Report d'office de ce qui n'a pas été fait, compteur de relances incrémenté |

Deux règles comptent plus que les autres :

**Quand il n'y a rien à dire, le système se tait.** Un bilan vide tous les matins ferait couper les notifications en une semaine.

**Une notification est enregistrée avant d'être envoyée.** Le bot vient vider la file et dit ce qu'il a réussi à transmettre ; un échec laisse le message en attente plutôt que de le perdre.

```bash
curl -H "X-Cle-Api: $CLE" localhost:8000/notifications
curl -X POST -H "X-Cle-Api: $CLE" localhost:8000/notifications/12/envoyee
```

L'ordonnanceur et les endpoints appellent les **mêmes fonctions**. Il n'y a donc jamais deux chemins de code pour la même opération, et le chemin de nuit — celui qu'on ne regarde jamais — reste couvert par les tests.

## Le bot Telegram

Il tourne dans le même processus que l'API — pour deux utilisateurs, un conteneur de plus ne se justifie pas. Sans `TELEGRAM_TOKEN`, il ne démarre pas et l'API fonctionne normalement, les notifications restant en file.

**S'appairer** : envoyer `/demarrer TA_CLE_API` au bot. La clé sert de mot de passe — sans elle, quiconque trouve le nom du bot recevrait le planning.

| Commande | Effet |
|---|---|
| `/planning` `/demain` | Ce qui est prévu, horaires puis rappels |
| `/retards` | Ce qui traîne, avec les boutons |
| `/stock` | Uniforme et date limite de la prochaine lessive |
| `/conflits` | Cours en double à départager |
| `/collecter` | Forcer une collecte |
| `/lien CODE URL` | Donner l'URL d'un flux — le message est effacé aussitôt, il contient un jeton |
| `/oublie` | Délier ce compte |

Les rappels du soir portent trois boutons : **Fait**, **Plus tard**, **Non**. Aucune notification n'est envoyée entre 23h30 et 7h30 : faire vibrer un téléphone à 3h du matin pour une poussière est le meilleur moyen de faire couper les notifications.

Toute la logique vit dans `conversation.py`, qui se teste sans parler à Telegram. `bot.py` ne fait que brancher des commandes et des boutons dessus — sinon, vérifier qu'un bouton « Fait » valide la bonne occurrence demanderait un service extérieur.
