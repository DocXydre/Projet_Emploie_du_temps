# Les définitions

Ce dossier contient les fonctions, les vues et les déclencheurs de la base, tels
qu'ils doivent être. `sql/appliquer.sh` le recharge en entier à chaque passage,
après les migrations.

```
fonctions/<nom>.sql    une fonction par fichier, le fichier porte son nom
vues/NN_<nom>.sql      une vue par fichier, le numéro donne l'ordre de création
declencheurs.sql       tous les déclencheurs
```

## Pourquoi

Jusqu'à la migration 047, une fonction se modifiait en recopiant son corps
entier dans une migration nouvelle. `placer_taches` existait ainsi en trois
versions dans trois fichiers, et la bonne était celle du dernier à en parler.
Rejouer un vieux fichier réinstallait une ancienne version sans rien dire.

Ici, chaque fonction n'est écrite qu'à un endroit. Pour savoir ce qu'elle fait,
on ouvre son fichier. Pour la changer, on le modifie : `git diff` montre alors
les lignes changées, et non deux cents lignes recopiées.

Les migrations 001 à 047 gardent leurs anciennes définitions. Elles racontent
l'histoire et servent encore à construire une base neuve, mais ce dossier passe
après elles et a toujours le dernier mot.

## Les règles

**Changer une fonction** : modifier son fichier, pousser. Rien d'autre.

**Ajouter une fonction** : créer `fonctions/<nom>.sql`, avec `CREATE OR REPLACE
FUNCTION` et son `COMMENT ON`.

**Changer une signature ou un type de retour** : PostgreSQL ne remplace pas une
fonction dont les arguments changent, il en crée une seconde à côté. Il faut
donc une migration qui retire l'ancienne (`DROP FUNCTION nom(arguments)`), puis
le fichier modifié.

**Supprimer une fonction ou une vue** : supprimer son fichier, et écrire une
migration qui fait le `DROP`. Le chargement ne retire que ce qu'il recrée.

**Changer une vue** : modifier son fichier. Les vues sont retirées puis recréées
à chaque passage, donc ajouter ou retirer une colonne ne demande rien de plus.
Une migration qui modifie une colonne dont une vue dépend peut retirer la vue
sans crainte : elle revient juste après.

**Une migration ne définit plus rien de tout cela.** Passé 047, `appliquer.sh`
refuse une migration qui contient `CREATE FUNCTION`, `CREATE VIEW` ou `CREATE
TRIGGER`, avant d'avoir appliqué quoi que ce soit.

## Quand une migration a besoin d'une fonction à jour

Les migrations passent avant les définitions. Une étape qui doit appeler une
fonction dans sa nouvelle version, un recalcul après un changement de règle par
exemple, va dans `sql/apres/NNN_<nom>.sql`. Ces fichiers passent une seule fois,
après les définitions, et sont suivis dans `schema_migration` comme les
migrations.

## L'ordre de chargement

1. Les fonctions, par ordre alphabétique, sans vérification de leur corps
   (`check_function_bodies = off`) : elles se citent entre elles et citent les
   vues, et l'ordre alphabétique ne sait rien de ces dépendances.
2. Les vues, retirées dans l'ordre inverse de leur numéro puis recréées. Une vue
   qui en lit une autre doit porter un numéro plus grand.
3. Les déclencheurs.

Le tout dans une transaction : si une définition est fausse, la base garde les
précédentes en entier.
