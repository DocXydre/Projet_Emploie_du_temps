#!/usr/bin/env bash
# Les tests du serveur, sur une base à part.
#
#   ./outils/tests.sh                      toute la suite
#   ./outils/tests.sh tests/test_foyer.py  un fichier, ou tout argument de pytest
#
# Les tests vident la base qu'on leur donne : ils tournent ici sur
# « planif_test », jamais sur la base locale ni sur la fausse base.
#
# Ils tournent dans l'image « essais » (l'API, plus git et psql pour les tests du
# déploiement et des migrations), avec un environnement vide et hors du
# dossier du dépôt. Sinon la configuration lit .env et local/coach.env (hôte
# public, boîte de courriels, jeton SNCF, modèle du coach), et une dizaine de
# tests échouent sans rien de cassé : ils vérifient justement ce qui se passe
# sans ces réglages. Aucun appel payant ne part.

set -euo pipefail

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RACINE"
COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.local.yml
         -f docker-compose.maquette.yml)

"${COMPOSE[@]}" up -d db >/dev/null
docker exec planif-db psql -U planif -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname = 'planif_test'" | grep -q 1 \
    || docker exec planif-db createdb -U planif planif_test

ARGUMENTS=("$@")
[ ${#ARGUMENTS[@]} -eq 0 ] && ARGUMENTS=(tests)
CIBLES=()
for a in "${ARGUMENTS[@]}"; do
    case "$a" in tests*) CIBLES+=("/app/$a") ;; *) CIBLES+=("$a") ;; esac
done

# -rs : un test sauté dit pourquoi. Trente-trois l'étaient sans un mot, faute
# de git et de psql dans l'image de l'API.
"${COMPOSE[@]}" --profile essais run --rm --no-deps --build essais sh -c '
    cd /tmp && env -i PATH="$PATH" HOME="$HOME" PYTHONPATH=/app PLANIF_RACINE=/app \
        POSTGRES_USER="$POSTGRES_USER" POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
        POSTGRES_DB=planif_test DB_HOTE="$DB_HOTE" DB_PORT="$DB_PORT" \
        ORDONNANCEUR_ACTIF=false \
        python -m pytest -q -rs -p no:cacheprovider --rootdir=/app "$@"
' pytest "${CIBLES[@]}"
