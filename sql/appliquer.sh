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

# Seuls les fichiers numérotés sont des migrations. Le scénario de test, lui,
# n'a pas de numéro : il ne doit jamais être rejoué automatiquement.
applique=0
rejoue=0
divergents=""
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
        if head -5 "$fichier" | grep -qi "rejouable"; then
            echo "↻ $nom (empreinte inconnue, rejoué par sécurité)"
            psql_exec < "$fichier"
            rejoue=$((rejoue + 1))
        else
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
        if ! head -5 "$fichier" | grep -qi "rejouable"; then
            divergents="$divergents $nom"
            echo "! $nom a changé mais ne se rejoue pas : écris une nouvelle migration"
            continue
        fi
        echo "↻ $nom (modifié, rejoué)"
        rejoue=$((rejoue + 1))
    else
        echo "→ $nom"
        applique=$((applique + 1))
    fi

    psql_exec < "$fichier"
    psql_exec -c "INSERT INTO schema_migration (fichier, empreinte)
                  VALUES ('$nom', '$empreinte')
                  ON CONFLICT (fichier)
                  DO UPDATE SET empreinte = EXCLUDED.empreinte, applique_le = now();"
done

echo
echo "$applique migration(s) appliquée(s), $rejoue rejouée(s)."
if [ -n "$divergents" ]; then
    echo
    echo "Attention — ces fichiers ont changé sans être rejouables :$divergents"
    echo "Leurs modifications ne sont PAS en base."
fi

echo
echo "Contenu :"
psql_exec --tuples-only --command "
    SELECT '  ' || count(*) || ' tâches, '
           || (SELECT count(*) FROM enchainement) || ' enchaînements, '
           || (SELECT count(*) FROM source)       || ' sources, '
           || (SELECT count(*) FROM article_travail) || ' articles'
      FROM tache;"
