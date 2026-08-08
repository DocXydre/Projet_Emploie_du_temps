#!/usr/bin/env bash
# Sauvegarde quotidienne de la base.
#
# Une sauvegarde jamais restauree n'est pas une sauvegarde : lancer
# restauration.sh au moins une fois avant la mise en production (cf. 10).
#
# Cron suggere :
#   15 4 * * * /chemin/vers/projet/infra/scripts/sauvegarde.sh >> /var/log/planif-sauvegarde.log 2>&1

set -euo pipefail

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DESTINATION="${PLANIF_DOSSIER_SAUVEGARDES:-$RACINE/sauvegardes}"
RETENTION_JOURS="${PLANIF_RETENTION_JOURS:-30}"
CONTENEUR="${PLANIF_CONTENEUR_BASE:-planif-base}"

# shellcheck disable=SC1091
[ -f "$RACINE/.env" ] && set -a && . "$RACINE/.env" && set +a

BASE="${POSTGRES_DB:-planif}"
UTILISATEUR="${POSTGRES_USER:-planif}"
HORODATAGE="$(date -u +%Y%m%dT%H%M%SZ)"
FICHIER="$DESTINATION/planif-$HORODATAGE.sql.gz"

mkdir -p "$DESTINATION"

echo "[$(date -u +%FT%TZ)] Sauvegarde de $BASE vers $FICHIER"
docker exec "$CONTENEUR" pg_dump --username="$UTILISATEUR" --format=plain --no-owner "$BASE" \
  | gzip -9 > "$FICHIER"

# Chiffrement si une cle publique GPG est configuree. La copie hors machine est
# assuree par rsync/rclone dans un script appelant, pas ici.
if [ -n "${PLANIF_GPG_DESTINATAIRE:-}" ]; then
  gpg --batch --yes --encrypt --recipient "$PLANIF_GPG_DESTINATAIRE" "$FICHIER"
  rm -f "$FICHIER"
  FICHIER="$FICHIER.gpg"
  echo "Sauvegarde chiffree : $FICHIER"
fi

TAILLE="$(du -h "$FICHIER" | cut -f1)"
echo "Termine : $FICHIER ($TAILLE)"

echo "Purge des sauvegardes de plus de $RETENTION_JOURS jours"
find "$DESTINATION" -name 'planif-*.sql.gz*' -type f -mtime "+$RETENTION_JOURS" -print -delete

# Un dossier de sauvegarde vide est une panne silencieuse : on le signale.
if [ "$(find "$DESTINATION" -name 'planif-*.sql.gz*' -type f | wc -l)" -eq 0 ]; then
  echo "ALERTE : aucune sauvegarde presente apres execution" >&2
  exit 1
fi
