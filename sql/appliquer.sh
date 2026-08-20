#!/usr/bin/env bash
# Applique les fichiers SQL dans l'ordre, dans une seule transaction.
#
#   ./sql/appliquer.sh            applique tout sur la base courante
#   ./sql/appliquer.sh --recreer  supprime et recrée le schéma avant d'appliquer
#
# Il n'y a pas d'outil de migration : à ce stade du projet, rejouer les fichiers
# depuis zéro est plus simple à comprendre et à déboguer qu'un versionnement.
# Le jour où la base contiendra des données qu'on ne veut pas perdre, on passera
# à des fichiers incrémentaux numérotés.

set -euo pipefail

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTENEUR="${PLANIF_CONTENEUR:-planif-db}"

# shellcheck disable=SC1091
[ -f "$RACINE/.env" ] && set -a && . "$RACINE/.env" && set +a

BASE="${POSTGRES_DB:-planif}"
UTILISATEUR="${POSTGRES_USER:-planif}"

psql_exec() {
    docker exec -i "$CONTENEUR" psql --username="$UTILISATEUR" --dbname="$BASE" \
        --set ON_ERROR_STOP=1 --quiet "$@"
}

if [ "${1:-}" = "--recreer" ]; then
    echo "Suppression du schéma public"
    psql_exec -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'
fi

# Seuls les fichiers numérotés sont des migrations. Le scénario de test, lui,
# n'a pas de numéro : il ne doit jamais être rejoué automatiquement.
for fichier in "$RACINE"/sql/0[0-9][0-9]_*.sql; do
    echo "→ $(basename "$fichier")"
    psql_exec < "$fichier"
done

echo
echo "Contenu :"
psql_exec --tuples-only --command "
    SELECT '  ' || count(*) || ' tâches, '
           || (SELECT count(*) FROM enchainement) || ' enchaînements, '
           || (SELECT count(*) FROM source)       || ' sources, '
           || (SELECT count(*) FROM article_travail) || ' articles'
      FROM tache;"
