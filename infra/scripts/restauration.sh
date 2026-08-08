#!/usr/bin/env bash
# Restauration d'une sauvegarde.
#
#   ./infra/scripts/restauration.sh sauvegardes/planif-20260806T041500Z.sql.gz
#
# ATTENTION : ecrase le contenu de la base cible. A executer une premiere fois
# sur une base de test avant la mise en production.

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage : $0 <fichier.sql.gz>" >&2
  exit 2
fi

ARCHIVE="$1"
RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTENEUR="${PLANIF_CONTENEUR_BASE:-planif-base}"

# shellcheck disable=SC1091
[ -f "$RACINE/.env" ] && set -a && . "$RACINE/.env" && set +a

BASE="${POSTGRES_DB:-planif}"
UTILISATEUR="${POSTGRES_USER:-planif}"

[ -f "$ARCHIVE" ] || { echo "Fichier introuvable : $ARCHIVE" >&2; exit 1; }

read -r -p "Restaurer $ARCHIVE dans la base '$BASE' et ECRASER son contenu ? [oui/non] " reponse
[ "$reponse" = "oui" ] || { echo "Annule."; exit 0; }

echo "Recreation du schema public"
docker exec -i "$CONTENEUR" psql --username="$UTILISATEUR" --dbname="$BASE" \
  -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'

echo "Restauration en cours"
gunzip -c "$ARCHIVE" | docker exec -i "$CONTENEUR" psql --username="$UTILISATEUR" --dbname="$BASE"

echo "Verification"
docker exec -i "$CONTENEUR" psql --username="$UTILISATEUR" --dbname="$BASE" \
  -c "SELECT count(*) AS tables FROM information_schema.tables WHERE table_schema = 'public';"

echo "Restauration terminee. Redemarrer le coeur metier : docker compose restart coeur"
