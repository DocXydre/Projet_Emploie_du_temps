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
| Une tâche est en retard | Vue `v_occurrence` |

La base refuse ce qui est incohérent, même si un script ou une saisie manuelle contourne l'API un jour.

## État

Le socle SQL est écrit et vérifié : 9 tables, 6 vues, 12 fonctions, 6 triggers. L'API FastAPI, l'export iCalendar et le bot Telegram viennent ensuite.

## Démarrage

```bash
cp .env.example .env
# Renseigner POSTGRES_PASSWORD, puis les deux clés d'API :
LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 48; echo

docker compose up -d
./sql/appliquer.sh
```

## Structure

```
sql/
  001_schema.sql       tables, CHECK, contraintes d'exclusion
  002_vues.sql         planning, retards, santé des sources, stock
  003_fonctions.sql    disponibilités, génération, projection, placement
  004_triggers.sql     récurrence, enchaînements, machine unique, stock
  005_donnees.sql      sources, tâches, enchaînements, articles
  999_scenario_test.sql   déroulé d'une semaine type, avec assertions
  appliquer.sh
docker-compose.yml
cahier-des-charges.md
```

Les fichiers sont rejoués depuis zéro à chaque fois, il n'y a pas encore d'outil de migration. C'est volontaire : tant que la base ne contient pas de données à préserver, `--recreer` est plus simple à comprendre qu'un versionnement.

## Vérifier

```bash
./sql/appliquer.sh --recreer
docker exec -i planif-db psql -U planif -d planif < sql/999_scenario_test.sql
```

Le scénario monte une semaine type — cinq journées de cours, quatre shifts, du sommeil — puis vérifie :

- qu'un chevauchement de shifts est **refusé par la base** ;
- que les 11 tâches trouvent une place, les rappels sur des journées entières et les machines à 21h45 ;
- qu'aucune tâche à heure imposée n'en chevauche une autre, et qu'aucun jour ne porte deux machines ;
- que valider la poussière crée la suivante **à partir de la date réelle** et repositionne l'aspirateur existant au lieu d'en créer un second ;
- que revalider une tâche close et valider dans le futur sont refusés ;
- que le stock d'uniforme déclenche une lessive, et alerte quand il est trop tard pour que le linge sèche ;
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

## Suite

L'API FastAPI par-dessus ce socle : endpoints de lecture branchés sur les vues, endpoints d'action branchés sur les fonctions, export `.ics`, puis le bot Telegram.
