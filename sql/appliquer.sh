#!/usr/bin/env bash
# Applique les migrations qui ne l'ont pas encore été.
#
#   ./sql/appliquer.sh            applique ce qui manque
#   ./sql/appliquer.sh --recreer  repart de zéro, en effaçant tout
#
# Chaque fichier appliqué est enregistré dans `schema_migration`. Relancer le
# script est donc sans effet tant qu'aucun fichier n'a été ajouté — ce qui
# compte dès qu'il y a en base des données qu'on ne veut pas perdre.

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

if [ "${1:-}" = "--recreer" ]; then
    echo "Suppression du schéma public"
    psql_exec -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'
fi

psql_exec -c "
    CREATE TABLE IF NOT EXISTS schema_migration (
        fichier     TEXT        PRIMARY KEY,
        applique_le TIMESTAMPTZ NOT NULL DEFAULT now()
    );"

# Seuls les fichiers numérotés sont des migrations. Le scénario de test, lui,
# n'a pas de numéro : il ne doit jamais être rejoué automatiquement.
applique=0
for fichier in "$RACINE"/sql/0[0-9][0-9]_*.sql; do
    nom="$(basename "$fichier")"

    deja="$(psql_exec --tuples-only --no-align \
            --command "SELECT 1 FROM schema_migration WHERE fichier = '$nom'")"
    if [ -n "$deja" ]; then
        echo "· $nom (déjà appliqué)"
        continue
    fi

    echo "→ $nom"
    psql_exec < "$fichier"
    psql_exec -c "INSERT INTO schema_migration (fichier) VALUES ('$nom');"
    applique=$((applique + 1))
done

echo
echo "$applique migration(s) appliquée(s)."

echo
echo "Contenu :"
psql_exec --tuples-only --command "
    SELECT '  ' || count(*) || ' tâches, '
           || (SELECT count(*) FROM enchainement) || ' enchaînements, '
           || (SELECT count(*) FROM source)       || ' sources, '
           || (SELECT count(*) FROM article_travail) || ' articles'
      FROM tache;"
