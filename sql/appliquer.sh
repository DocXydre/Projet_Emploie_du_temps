#!/usr/bin/env bash
# Applique les migrations qui ne l'ont pas encore été.
#
#   ./sql/appliquer.sh                      applique ce qui manque
#   ./sql/appliquer.sh --recreer            repart de zéro, en effaçant tout
#   ./sql/appliquer.sh --adopter FICHIER    accepte un fichier modifié sans le rejouer
#
# Chaque fichier appliqué est enregistré dans `schema_migration`. Relancer le
# script est donc sans effet tant qu'aucun fichier n'a été ajouté — ce qui
# compte dès qu'il y a en base des données qu'on ne veut pas perdre.
#
# Trois temps, toujours dans cet ordre :
#
#   1. sql/NNN_*.sql         les migrations : tables, colonnes, données. Une fois.
#   2. sql/definitions/      les fonctions, les vues, les déclencheurs. À chaque
#                            passage : la base reçoit ce que dit le dépôt.
#   3. sql/apres/NNN_*.sql   les rattrapages qui appellent une fonction à jour.
#                            Une fois.
#
# Jusqu'à la migration 047, les fonctions étaient réécrites de migration en
# migration, et la version en vigueur était celle du dernier fichier à en
# parler. Elles ont maintenant un fichier chacune, dans sql/definitions/, et les
# migrations suivantes n'ont plus le droit d'en définir.

set -euo pipefail

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTENEUR="${PLANIF_CONTENEUR:-planif-db}"

# On ne fait pas `source .env` : le fichier contient des URL avec des crochets
# (`types[]=shift`), que le shell prendrait pour des indices de tableau. On lit
# donc uniquement les deux variables nécessaires, littéralement.
lire_env() {
    local cle="$1" defaut="$2" valeur
    [ -f "$RACINE/.env" ] || { echo "$defaut"; return; }
    valeur="$(grep -m1 "^${cle}=" "$RACINE/.env" | cut -d= -f2- | tr -d "\"'" | tr -d '\r')"
    echo "${valeur:-$defaut}"
}

BASE="$(lire_env POSTGRES_DB planif)"
UTILISATEUR="$(lire_env POSTGRES_USER planif)"

psql_exec() {
    docker exec -i "$CONTENEUR" psql --username="$UTILISATEUR" --dbname="$BASE" \
        --set ON_ERROR_STOP=1 --quiet "$@"
}

# Un fichier entier dans une seule transaction. PostgreSQL sait annuler du DDL :
# une migration qui casse à la ligne 200 n'en laisse donc rien, au lieu de
# laisser les 199 premières appliquées et la base entre deux versions.
jouer() {
    docker exec -i "$CONTENEUR" psql --username="$UTILISATEUR" --dbname="$BASE" \
        --set ON_ERROR_STOP=1 --quiet --single-transaction --file=- < "$1"
}

# La dernière migration écrite à l'ancienne manière, fonctions comprises.
DERNIERE_ANCIENNE=47

# Le flux SQL des définitions, dans l'ordre où il se charge.
#
# Les fonctions d'abord, sans vérifier leur corps : elles se citent entre elles
# et citent les vues, et l'ordre alphabétique ne sait rien de ces dépendances.
# Les vues ensuite, retirées puis recréées : CREATE OR REPLACE VIEW refuse de
# changer une colonne, alors qu'ici le fichier doit toujours avoir raison. Leur
# numéro donne l'ordre de création, et l'ordre inverse celui du retrait.
flux_definitions() {
    local d="$RACINE/sql/definitions" f vues i nom
    echo "SET LOCAL check_function_bodies = off;"
    for f in "$d"/fonctions/*.sql; do cat "$f"; echo; done
    vues=("$d"/vues/[0-9][0-9]_*.sql)
    for ((i = ${#vues[@]} - 1; i >= 0; i--)); do
        nom="$(basename "${vues[i]}" .sql)"
        echo "DROP VIEW IF EXISTS ${nom#*_};"
    done
    for f in "${vues[@]}"; do cat "$f"; echo; done
    cat "$d/declencheurs.sql"
}

# Tout dans une transaction : si une seule définition est fausse, la base garde
# les précédentes en entier, vues comprises.
charger_definitions() {
    flux_definitions | docker exec -i "$CONTENEUR" psql --username="$UTILISATEUR" \
        --dbname="$BASE" --set ON_ERROR_STOP=1 --quiet --single-transaction --file=-
}

# Une migration récente qui définit une fonction, une vue ou un déclencheur :
# on s'arrête avant d'avoir rien appliqué. Sans ce refus, la définition du
# dossier l'écraserait dans la minute, et la migration mentirait sur ce qu'elle
# fait. Retirer (DROP) reste permis : c'est même le seul moyen de changer une
# signature.
refuser_les_definitions_en_migration() {
    local fichier nom fautes="" trouve
    for fichier in "$RACINE"/sql/0[0-9][0-9]_*.sql; do
        nom="$(basename "$fichier")"
        [ "$((10#${nom:0:3}))" -gt "$DERNIERE_ANCIENNE" ] || continue
        trouve="$(grep -v '^[[:space:]]*--' "$fichier" \
            | grep -oiE "CREATE([[:space:]]+OR[[:space:]]+REPLACE)?[[:space:]]+(CONSTRAINT[[:space:]]+)?(FUNCTION|PROCEDURE|VIEW|TRIGGER)[[:space:]]+[a-z_0-9.]+" \
            | awk '{ print tolower($NF) }' | sort -u | tr '\n' ' ' || true)"
        [ -n "$trouve" ] && fautes="$fautes
  $nom : $trouve"
    done
    [ -z "$fautes" ] && return 0
    echo "Ces migrations définissent des fonctions, des vues ou des déclencheurs :$fautes"
    echo "Depuis la migration 0$DERNIERE_ANCIENNE, leur place est dans sql/definitions/,"
    echo "un fichier par fonction. Rien n'a été appliqué."
    return 1
}

refuser_les_definitions_en_migration

if [ "${1:-}" = "--recreer" ]; then
    echo "Suppression des schémas public et archive"
    psql_exec -c 'DROP SCHEMA IF EXISTS archive CASCADE;
                  DROP SCHEMA public CASCADE; CREATE SCHEMA public;'
fi

psql_exec -c "
    CREATE TABLE IF NOT EXISTS schema_migration (
        fichier     TEXT        PRIMARY KEY,
        empreinte   TEXT,
        applique_le TIMESTAMPTZ NOT NULL DEFAULT now()
    );
    ALTER TABLE schema_migration ADD COLUMN IF NOT EXISTS empreinte TEXT;"

# Un fichier corrigé doit repartir en base, sinon la correction ne sert à rien.
# Mais tous ne peuvent pas être rejoués : réexécuter des CREATE TABLE ou des
# INSERT de données de référence échouerait, ou dupliquerait. Les fichiers qui
# le supportent le déclarent en tête, par un commentaire « rejouable ». Les
# autres sont signalés et laissés tels quels, à traiter par une migration
# nouvelle — c'est le seul moyen sûr de modifier une table déjà remplie.
empreinte_de() {
    if command -v sha256sum > /dev/null; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# Un fichier se déclare rejouable dans ses cinq premières lignes. « NON
# rejouable » contient le même mot : sans l'écarter, les deux migrations qui
# effacent des lignes passaient pour rejouables, et un caractère changé dans
# l'une d'elles aurait relancé l'effacement.
est_rejouable() {
    # Sans `grep -q` : il rend la main dès la première ligne trouvée, et avec
    # `pipefail` le grep d'avant, coupé en plein travail, ferait passer le
    # fichier pour non rejouable.
    [ -n "$(head -5 "$1" | grep -i "rejouable" \
            | grep -ivE "(non|pas)[ -]*rejouable" || true)" ]
}

# Ce qu'un fichier installe ou retire : fonctions, vues, triggers, contraintes.
# Les commentaires sont écartés, ils citent souvent des noms sans rien définir.
objets_de() {
    grep -v '^[[:space:]]*--' "$1" \
      | grep -oiE "((CREATE([[:space:]]+OR[[:space:]]+REPLACE)?|DROP)[[:space:]]+(FUNCTION|VIEW|TRIGGER)|(ADD|DROP)[[:space:]]+CONSTRAINT)[[:space:]]+(IF[[:space:]]+EXISTS[[:space:]]+)?[a-z_0-9]+" \
      | awk '{ print tolower($NF) }' | sort -u || true
}

# Ce que des migrations plus récentes, déjà en base, ont repris à ce fichier.
#
# C'est le piège que cette fonction ferme. `placer_taches` est écrite dans 003,
# réécrite dans 033 puis dans 044. Rejouer 003 parce qu'on y a corrigé une
# virgule réinstallait la version de 003, qui appelle une fonction supprimée
# depuis : le placement cassait, pour un commentaire.
#
# Seules les migrations déjà appliquées comptent. Une migration encore en
# attente passera après et aura de toute façon le dernier mot.
repris_depuis() {
    local nom miens suivant ns
    nom="$(basename "$1")"
    miens="$(objets_de "$1")"
    [ -n "$miens" ] || return 0

    for suivant in "$RACINE"/sql/0[0-9][0-9]_*.sql; do
        ns="$(basename "$suivant")"
        [[ "$ns" > "$nom" ]] || continue
        grep -qxF "$ns" <<< "$APPLIQUES" || continue
        comm -12 <(printf '%s\n' "$miens") <(objets_de "$suivant") \
          | sed "s/\$/ (repris par ${ns:0:3})/"
    done | sort -u
}

if [ "${1:-}" = "--adopter" ]; then
    # Pour la virgule corrigée dans un commentaire : on prend acte du nouveau
    # contenu sans rien exécuter. À n'utiliser que si le changement ne touche
    # pas au SQL, puisque rien n'en arrivera en base.
    demande="${2:?nom du fichier attendu}"
    case "$demande" in
        */apres/*|apres/*) connu="apres/$(basename "$demande")" ;;
        *)                 connu="$(basename "$demande")" ;;
    esac
    cible="$RACINE/sql/$connu"
    [ -f "$cible" ] || { echo "Fichier inconnu : $cible" >&2; exit 1; }
    psql_exec -c "UPDATE schema_migration
                     SET empreinte = '$(empreinte_de "$cible")'
                   WHERE fichier = '$connu';"
    echo "· $connu : contenu actuel adopté, rien n'a été rejoué."
    exit 0
fi

# Ce qui est déjà en base au début du passage, pour savoir quelles migrations
# plus récentes ont pu reprendre un fichier modifié.
APPLIQUES="$(psql_exec --tuples-only --no-align \
             --command "SELECT fichier FROM schema_migration")"

# Seuls les fichiers numérotés sont des migrations. Le scénario de test, lui,
# n'a pas de numéro : il ne doit jamais être rejoué automatiquement.
applique=0
rejoue=0
divergents=""
depasses=""

# Refuse de rejouer un fichier dont une partie a été reprise depuis, et dit
# quoi. Rend 0 quand le rejeu est sûr.
rejeu_sur() {
    local repris
    repris="$(repris_depuis "$1")"
    [ -z "$repris" ] && return 0

    depasses="$depasses $(basename "$1")"
    echo "! $(basename "$1") a changé, mais des migrations plus récentes ont repris"
    echo "  une partie de ce qu'il définit. Le rejouer remettrait d'anciennes versions :"
    printf '%s\n' "$repris" | head -6 | sed 's/^/      /'
    [ "$(printf '%s\n' "$repris" | wc -l)" -gt 6 ] && echo "      ..."
    echo "  Rien n'a été touché."
    return 1
}
for fichier in "$RACINE"/sql/0[0-9][0-9]_*.sql; do
    nom="$(basename "$fichier")"
    empreinte="$(empreinte_de "$fichier")"

    connue="$(psql_exec --tuples-only --no-align \
              --command "SELECT COALESCE(empreinte, '') FROM schema_migration
                          WHERE fichier = '$nom'")"

    if [ -z "$connue" ] && [ -n "$(psql_exec --tuples-only --no-align \
            --command "SELECT 1 FROM schema_migration WHERE fichier = '$nom'")" ]; then
        # Appliqué avant que les empreintes n'existent : on ne sait pas si le
        # fichier a changé depuis. Pour un fichier rejouable, la réponse sûre
        # est de le rejouer — c'est gratuit, et cela garantit que la base
        # correspond au dépôt. Enregistrer l'empreinte sans rejouer figerait
        # au contraire une divergence pour toujours.
        if est_rejouable "$fichier" && [ -z "$(repris_depuis "$fichier")" ]; then
            echo "↻ $nom (empreinte inconnue, rejoué par sécurité)"
            jouer "$fichier"
            rejoue=$((rejoue + 1))
        else
            # Non rejouable, ou repris depuis par une migration plus récente :
            # dans les deux cas le rejouer ferait plus de mal que de bien.
            echo "· $nom (déjà appliqué, empreinte adoptée)"
        fi
        psql_exec -c "UPDATE schema_migration
                         SET empreinte = '$empreinte', applique_le = now()
                       WHERE fichier = '$nom';"
        continue
    fi

    if [ "$connue" = "$empreinte" ]; then
        echo "· $nom (déjà appliqué)"
        continue
    fi

    if [ -n "$connue" ]; then
        if ! est_rejouable "$fichier"; then
            divergents="$divergents $nom"
            echo "! $nom a changé mais ne se rejoue pas : écris une nouvelle migration"
            continue
        fi
        rejeu_sur "$fichier" || continue
        echo "↻ $nom (modifié, rejoué)"
        rejoue=$((rejoue + 1))
    else
        echo "→ $nom"
        applique=$((applique + 1))
    fi

    jouer "$fichier"
    psql_exec -c "INSERT INTO schema_migration (fichier, empreinte)
                  VALUES ('$nom', '$empreinte')
                  ON CONFLICT (fichier)
                  DO UPDATE SET empreinte = EXCLUDED.empreinte, applique_le = now();"
done

# Les définitions, à chaque passage. C'est ce qui rend une vieille migration
# inoffensive : quoi qu'elle ait réinstallé, le dossier a le dernier mot.
charger_definitions
echo "✓ définitions ($(find "$RACINE/sql/definitions/fonctions" -name '*.sql' | wc -l | tr -d ' ') fonctions," \
     "$(find "$RACINE/sql/definitions/vues" -name '*.sql' | wc -l | tr -d ' ') vues, déclencheurs)"

# Les rattrapages : des étapes à ne jouer qu'une fois, mais qui ont besoin des
# fonctions à jour. Recalculer des propositions après en avoir changé la règle,
# par exemple. Ils passent après toutes les migrations : aucune migration ne
# doit donc compter sur eux.
for fichier in "$RACINE"/sql/apres/[0-9][0-9][0-9]_*.sql; do
    [ -f "$fichier" ] || continue
    nom="apres/$(basename "$fichier")"
    empreinte="$(empreinte_de "$fichier")"
    connue="$(psql_exec --tuples-only --no-align \
              --command "SELECT COALESCE(empreinte, '-') FROM schema_migration
                          WHERE fichier = '$nom'")"
    if [ "$connue" = "$empreinte" ]; then
        echo "· $nom (déjà appliqué)"
        continue
    fi
    if [ -n "$connue" ]; then
        divergents="$divergents $nom"
        echo "! $nom a changé mais ne se rejoue pas : écris un nouveau rattrapage"
        continue
    fi
    echo "→ $nom"
    jouer "$fichier"
    psql_exec -c "INSERT INTO schema_migration (fichier, empreinte)
                  VALUES ('$nom', '$empreinte');"
    applique=$((applique + 1))
done

echo
echo "$applique migration(s) appliquée(s), $rejoue rejouée(s)."
if [ -n "$divergents" ]; then
    echo
    echo "Attention : ces fichiers ont changé sans être rejouables :$divergents"
    echo "Leurs modifications ne sont PAS en base."
fi
if [ -n "$depasses" ]; then
    echo
    echo "Attention : ces fichiers ont changé après avoir été repris par d'autres :$depasses"
    echo "Leurs modifications ne sont PAS en base. Deux issues :"
    echo "  une nouvelle migration, si le changement touche au SQL ;"
    echo "  ./sql/appliquer.sh --adopter FICHIER, si ce n'est qu'un commentaire."
fi

echo
echo "Contenu :"
psql_exec --tuples-only --command "
    SELECT '  ' || count(*) FILTER (WHERE active) || ' tâches actives, '
           || (SELECT count(*) FROM enchainement) || ' enchaînements, '
           || (SELECT count(*) FROM source WHERE active) || ' sources suivies'
      FROM tache;"
