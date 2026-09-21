# Stock d'uniforme

Retiré en septembre 2026 par la migration `031_retrait_stock_uniforme.sql`, après
la démission de McDonald's.

## Ce que ça faisait

Le système comptait les t-shirts et pantalons de travail propres. Chaque journée
travaillée en salissait (un t-shirt par service, un pantalon tous les deux
services), une projection sur les shifts à venir repérait la rupture, et une
« lessive de travail » en priorité 1, non reportable, était posée assez tôt pour
que le linge ait le temps de sécher. Valider cette lessive mettait les articles
en séchage jusqu'à `disponible_le`.

## Ce qui a été retiré

| Où | Quoi |
|---|---|
| Base | fonctions `projeter_stock`, `declencher_lessive`, `consommer_uniforme`, `rattraper_uniforme`, `recaler_uniforme`, vue `v_stock`, triggers de `mouvement_stock`, colonne `tache.lave_uniforme` |
| Base | l'appel à `declencher_lessive` dans `placer_taches`, le bloc UNI-13 du trigger de validation |
| Base | la tâche `LESSIVE_TRAVAIL`, désactivée (son historique reste) |
| API | `api/routeurs/stock.py` (`/stock`, `/stock/projection`, `/stock/{code}/recaler`, `/stock/{code}/mouvement`) |
| Bot | `/stock`, `/recaler`, la ligne « Uniforme » du menu |
| Ordonnanceur | la consommation de l'uniforme à 00h02 |
| Cahier | règles UNI-1 à UNI-11 et UNI-13 à UNI-15, opération 3, tables ArticleTravail et MouvementStock |

UNI-12 (deux machines jamais le même jour) est restée : elle concerne la machine
à laver, pas le stock. La lessive de blanc, l'étendage et le pliage continuent.

## Ce qui a été gardé

**Les données.** `article_travail` et `mouvement_stock` sont dans le schéma
`archive` de la base, avec tout leur historique. Elles n'ont pas été effacées.

**Le code**, dans ce dossier :

| Fichier | Contenu |
|---|---|
| `sql/014_uniforme.sql` | la migration d'origine, sortie de `sql/` |
| `sql/schema.sql` | tables, vue, triggers et données de départ, extraits de la base |
| `sql/fonctions.sql` | les fonctions supprimées, et les deux morceaux retirés de fonctions encore vivantes |
| `sql/restaurer.sql` | remet la partie base en service, données comprises (testé) |
| `api/routeurs/stock.py` | le routeur, tel quel |
| `api/bot_stock.py`, `api/conversation_stock.py`, `api/ordonnanceur_uniforme.py` | le code retiré des modules du bot et de l'ordonnanceur, avec les lignes de branchement en en-tête |
| `tests/` | les tests du stock |
| `cahier.md` | les passages retirés du cahier des charges |

## Pour le remettre en service

1. Écrire une migration qui reprend `sql/restaurer.sql`.
2. Y recoller les deux morceaux notés en fin de `sql/fonctions.sql` dans les
   versions du moment de `placer_taches` et `trg_occurrence_apres_validation`.
3. Remettre `api/routeurs/stock.py` et son `include_router` dans `api/main.py`,
   puis les fonctions du bot, de la conversation et de l'ordonnanceur, en suivant
   les en-têtes des fichiers `api/*.py` de ce dossier.
4. Ramener les tests dans `tests/`, les règles dans le cahier.

Un nouvel emploi avec un uniforme différent demandera surtout de changer les
articles (`article_travail`) : les quantités, la durée de séchage et le nombre de
services qu'une pièce couvre sont des données, pas du code.
