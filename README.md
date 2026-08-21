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

Complet et vérifié : 14 tables, 9 vues, 27 fonctions, 6 triggers, 215 tests. Le système collecte, place, répartit, notifie et se pilote au bot.

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

## Le train

`/absent` suppose qu'on connaisse déjà ses dates. `/train` part de l'autre bout : le système cherche lui-même les creux, puis demande à la SNCF des horaires qu'on puisse réellement attraper.

```
/train

Fenêtres assez longues pour un aller-retour :

1. ven 28/08 17h35 → lun 31/08 08h00 (62 h)
2. ven 11/09 16h00 → lun 14/09 08h00 (64 h)

[Fenêtre 1]  [Fenêtre 2]
```

Choisir une fenêtre déclenche la recherche d'horaires. Le premier train proposé n'est pas le premier du soir mais **le premier qu'on puisse attraper** : trente minutes après la fin du dernier cours, le temps d'aller à la gare. Sans cette marge, le système proposerait un train qu'on regarde partir depuis l'amphi.

```
Tu finis à 17h35 : premier train attrapable après 18h05.

Aller :
[18h12 → 19h47 · TER direct]
[19h42 → 21h52 · TER, 1 correspondance à Lunéville]
```

Le retour se cherche dans l'autre sens. On ne veut pas le premier train qui ramène, on veut **le dernier qui ramène à temps** — chaque heure gagnée est une heure de plus sur place. Avec un cours à 16h30 et trente minutes pour rentrer de la gare, il faut être arrivé à 16h00 : le train proposé en premier est celui de 14h42, et les trois suivants sont de plus en plus tôt.

```
Retour — rentré avant 16h00. Du dernier train aux plus tôt :
[14h42 → 16h00 · TER direct]
[12h10 → 13h45 · TER direct]
[10h05 → 11h40 · TER, 1 correspondance à Lunéville]
[Retour à fixer plus tard]
```

Concrètement, la SNCF est interrogée **par heure d'arrivée** et non par heure de départ : demander les premiers trains après une heure donnée ne ferait jamais remonter ceux du soir. Le retour est aussi borné par le bas — pas moins de douze heures sur place, rester une heure à Saint-Dié n'est pas un séjour.

Le bouton **Retour à fixer plus tard** existe : partir sans savoir quand on rentre est un cas ordinaire, et refuser de l'enregistrer obligerait à choisir un horaire au hasard. L'absence court alors jusqu'à la prochaine obligation connue.

Une fois l'aller-retour retenu, l'absence est déclarée et le ménage se replace tout seul.

**Deux limites, assumées.** Le système n'achète pas le billet — une proposition retenue est une intention, pas une réservation. Et sans `SNCF_TOKEN`, les fenêtres se calculent quand même : seule la proposition d'horaires devient impossible, et le bot le dit au lieu de planter.

## Le billet acheté ailleurs

Acheter un billet est déjà une déclaration d'absence. La refaire à la main est du travail en double, et le travail en double finit par ne plus être fait. L'API lit les confirmations SNCF, et l'absence se déclare seule.

**Rien à changer à ton compte SNCF ni à ton adresse.** Sur Gmail, un libellé est un dossier IMAP : un filtre pose le libellé, et l'API ne lit que celui-là.

Dans Gmail → Paramètres → Filtres → *Créer un filtre* :

| Champ | Valeur |
|---|---|
| De | `sncf-connect.com OR info.sncf.com OR connect.sncf` |
| Action | Appliquer le libellé `SNCF` |

Coche *Appliquer aussi ce filtre aux conversations correspondantes* pour rattraper l'existant. Puis un mot de passe d'application : Google → Sécurité → validation en deux étapes → Mots de passe d'application. Le mot de passe habituel est refusé par IMAP.

```
IMAP_HOTE=imap.gmail.com
IMAP_UTILISATEUR=tmathis.dev@gmail.com
IMAP_MOT_DE_PASSE=le_mot_de_passe_d_application
IMAP_DOSSIER=SNCF
```

Sans filtre, `IMAP_DOSSIER=INBOX` fonctionne aussi : `IMAP_FILTRE_EXPEDITEUR=sncf` demande au serveur de ne rendre que ces courriels-là, plutôt que de rapatrier des milliers de messages pour en analyser trois.

**La boîte est ouverte en lecture seule**, et les messages lus avec `BODY.PEEK` : rien n'est marqué comme lu, rien n'est déplacé, rien n'est supprimé. Un système qui fait disparaître le gras des messages non lus dans le dos de son propriétaire ne se fait pardonner qu'une fois.

Ce qu'il faut savoir quand même : **un mot de passe d'application donne accès à tout le courrier**, pas seulement au libellé. Le nôtre ne lit que `SNCF`, mais le mot de passe lui-même n'est pas limité. Il vit dans ton `.env`, sur ta machine, dans un fichier non versionné — acceptable pour un usage personnel, et révocable en un clic depuis ton compte Google si tu changes d'avis.

La relève tourne toutes les deux heures, et `/billets` la déclenche à la main.

**Trois précautions, dans l'ordre où elles comptent.**

Seuls les domaines officiels de SNCF Connect sont analysés — `mail.sncf-connect.com`, `mail.sncfconnect.com`, `info.sncf.com`, `connect.sncf`. Les faux courriels au nom de la SNCF sont assez répandus pour que ce soit une vraie protection : sans elle, n'importe qui pourrait geler deux jours de ménage en t'envoyant un mail. La comparaison porte sur le domaine entier, pas sur un suffixe — `sncf-connect.com.attaquant.net` est refusé.

Une absence déclarée sans que tu l'aies demandée **s'annonce**, avec un bouton pour l'annuler. C'est la contrepartie de l'automatisme : le lecteur peut se tromper, et se tromper en silence est le pire défaut possible ici.

Un courriel légitime que le lecteur **n'a pas su lire est conservé** avec son motif, et `/billets` te le montre. Le format de ces mails ne nous appartient pas : il changera. Sans cette trace, le jour où plus aucune absence ne se déclarerait, rien n'indiquerait pourquoi.

**Une réserve honnête.** Le lecteur est écrit d'après la forme habituelle de ces récapitulatifs — une date, puis gare, heure, gare, heure — et non d'après un vrai courriel de ta boîte. Il faudra sans doute l'ajuster à la première confirmation réelle. C'est précisément à ça que sert le statut *illisible*.

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
| URL d'abonnement | http://localhost:8000/moi/calendrier |

## S'abonner depuis le téléphone

L'adresse du flux contient le nom de la machine. Y mettre une adresse IP condamne l'abonnement : elle change d'un réseau à l'autre, et le téléphone continue d'interroger une adresse qui ne répond plus. Le nom Bonjour du Mac, lui, ne change pas.

```bash
scutil --get LocalHostName        # → macbook-de-thomas
```

Dans `.env` :

```
HOTE_PUBLIC=macbook-de-thomas.local:8000
API_BIND=0.0.0.0
```

`API_BIND` compte autant que le reste : par défaut l'API n'écoute que sur la machine elle-même, et le téléphone ne la voit pas. `0.0.0.0` l'ouvre au réseau local — à ne faire que sur un réseau de confiance.

Puis, dans Telegram :

```
/calendrier
```

Le bot renvoie un lien `webcal://` qui ouvre directement la boîte d'abonnement. C'est tout l'intérêt de passer par lui : le jeton fait trente-deux caractères et personne ne le recopie sans se tromper. À défaut, l'adresse en clair est dans la même réponse, et sur iPhone l'abonnement manuel se fait par Réglages → Calendrier → Comptes → Ajouter → Autre → Ajouter un abonnement.

**Le lien n'est pas la clé d'API.** Il ne donne que la lecture du planning, parce qu'il vit en clair dans le téléphone, dans ses sauvegardes, et repart à chaque rafraîchissement. S'il fuite, `/calendrier renouveler` le révoque : il faut alors se réabonner, mais rien d'autre ne bouge.

Une réserve, qui décidera de l'utilité du système au quotidien : **rien de tout cela ne fonctionne quand le Mac est éteint ou endormi.** Le calendrier ne se rafraîchit plus, et surtout l'ordonnanceur ne tourne plus — pas de collecte, pas de bilan à 7h, pas de relance à 21h. Une machine allumée en permanence lève les deux problèmes à la fois.

## Structure

```
sql/
  001_schema.sql        tables, CHECK, contraintes d'exclusion
  002_vues.sql          planning, retards, santé des sources, stock
  003_fonctions.sql     disponibilités, génération, projection, placement
  004_triggers.sql      récurrence, enchaînements, machine unique, stock
  005_donnees.sql       sources, tâches, enchaînements, articles
  006_assignations.sql  qui fait quoi par défaut
  007_jeton_calendrier.sql  abonnement iCalendar séparé de la clé d'API
  008_trajets.sql       fenêtres de départ, propositions d'horaires
  009_courriels.sql     trace de ce qui a été lu dans la boîte
  scenario_test.sql     déroulé d'une semaine type, avec assertions
  appliquer.sh
api/
  main.py                  montage, erreurs normalisées, /sante, /planning.ics
  base.py                  pool psycopg, sans ORM
  securite.py              clé d'API, et jeton de calendrier pour le flux
  erreurs.py               SQLSTATE → statut HTTP
  calendrier.py            export iCalendar
  amorcage.py              URL des flux depuis l'environnement
  ordonnanceur.py          collectes, bilan, relance, report
  collecteurs/ics.py       lecture des flux, profils ade et easyatwork
  collecteurs/service.py   collecte et réconciliation, sans HTTP
  collecteurs/sncf.py      horaires de train, API Navitia
  collecteurs/courriel.py  confirmations d'achat, liste blanche et analyse
  trajets.py               fenêtres, propositions, absence qui en découle
  billets.py               du courriel lu à l'absence déclarée
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

## Les migrations

`./sql/appliquer.sh` applique ce qui manque, et rien d'autre. Chaque fichier est enregistré dans `schema_migration` avec l'empreinte de son contenu.

Un fichier **modifié** est rejoué s'il porte un commentaire `rejouable` en tête — c'est le cas de `002`, `003`, `004`, `007` et `008`, qui ne contiennent que des `CREATE OR REPLACE` et des `IF NOT EXISTS`. Sans ce mécanisme, corriger une fonction dans le dépôt ne changeait rien en base : la migration était marquée appliquée, et la correction ne partait jamais.

Les autres — `001` qui crée les tables, `005` et `006` qui insèrent — ne se rejouent pas. S'ils changent, le script le signale et n'applique rien : il faut écrire une migration nouvelle. C'est le seul moyen sûr de modifier une table déjà remplie.

`--recreer` efface tout et repart de zéro. À n'utiliser que sur une base sans données à perdre.

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
| `/absent JJ/MM JJ/MM lieu` | Je ne suis pas à l'appartement — le planning se refait aussitôt |
| `/train` | Aller à Saint-Dié : fenêtres, horaires proposés, absence déclarée |
| `/billets` | Relever la boîte, lister les voyages détectés et ceux qu'on n'a pas su lire |
| `/calendrier` | Le lien d'abonnement, envoyé là où on en a besoin. `renouveler` en donne un nouveau et coupe l'ancien |
| `/collecter` | Forcer une collecte |
| `/lien CODE URL` | Donner l'URL d'un flux — le message est effacé aussitôt, il contient un jeton |
| `/oublie` | Délier ce compte |

Les rappels du soir portent trois boutons : **Fait**, **Plus tard**, **Non**. Aucune notification n'est envoyée entre 23h30 et 7h30 : faire vibrer un téléphone à 3h du matin pour une poussière est le meilleur moyen de faire couper les notifications.

Toute la logique vit dans `conversation.py`, qui se teste sans parler à Telegram. `bot.py` ne fait que brancher des commandes et des boutons dessus — sinon, vérifier qu'un bouton « Fait » valide la bonne occurrence demanderait un service extérieur.
