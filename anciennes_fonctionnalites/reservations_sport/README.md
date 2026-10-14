# Réservations de sport

Retirées en octobre 2026 par la migration `065_retrait_reservations_sport.sql`
(lot 2 de la partie E du cahier de HAL). Chaque membre a HAL : c'est lui qui
propose les séances, sur quatre semaines (SPT-33).

## Ce que ça faisait

Trois semaines de sport étaient ouvertes. Chaque compte avait un minimum de
séances par semaine ; ce qui n'était pas choisi était réservé « à déterminer »
sur les meilleurs créneaux, pour que le ménage ne s'y mette pas. Le moteur
proposait au plus cinq séances par semaine, en tête les habitudes tirées des
choix passés. Le lundi matin, un message prévenait si la semaine n'avait pas
son minimum, et une réservation passée sans être choisie était constatée.
Tout se réglait dans le bot, par `/sport` et `/organiser`.

## Ce qui a été retiré

| Où | Quoi |
|---|---|
| Base | fonctions `organiser_sport`, `organiser_sport_semaine`, `propositions_sport`, `habitudes_sport`, `minimum_sport`, `regler_minimum_sport`, `alerte_sport_du_lundi`, `seances_a_determiner_passees`, `heures_seance_sport`, `meilleure_heure_sport`, `heures_candidates`, `sportifs` |
| Base | les réservations encore ouvertes (`occurrence.origine = 'quota'`) ; les closes restent, comme histoire |
| Base | `obstacle_seance_coach`, `bloc_seance_duree` et `duree_seance`, fusionnées dans `obstacle_seance` et `bloc_de_seance` |
| API | tout `api/sport.py` sauf les horaires des lieux, la séance posée à la main et les séances à deux |
| Ordonnanceur | l'alerte du lundi à 7h20, le constat des réservations passées toutes les 30 minutes |
| Bot | `/sport`, `/organiser`, `/piscine` et leurs boutons (le bot n'a plus que l'administration) |
| Cahier | SPT-5, 6, 18, 20, 22, 23, 27, 28, 30 ; SPT-19, 25 et 29 réduites (annexe 2) |

## Ce qui a été gardé

**Les données.** `choix_sport` (les habitudes) et `minimum_sport` (le minimum
de chaque compte) sont dans le schéma `archive`.

**Le code**, dans ce dossier :

| Fichier | Contenu |
|---|---|
| `sql/definitions/` | les fonctions telles qu'elles étaient, y compris celles qui ont été modifiées depuis |
| `api/sport.py` | le module entier : écrans du bot, propositions, habitudes, minimum |

## Le remettre en service

Il faudrait remettre la colonne `utilisateur.minimum_sport` et la table
`choix_sport` depuis l'archive, recharger les fonctions de `sql/definitions/`
(en reprenant les anciennes signatures d'`obstacle_seance` et
`bloc_de_seance`), et rebrancher l'appel à `organiser_sport()` dans
`placer_taches`. Sans un compte qui n'a pas HAL, il n'y a pas de raison de le faire.
