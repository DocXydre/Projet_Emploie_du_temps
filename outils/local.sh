#!/usr/bin/env bash
# La pile locale du coach, sur le Mac.
#
#   ./outils/local.sh demarrer      construit et lance la base et l'API
#   ./outils/local.sh restaurer     remplace la base locale par local/planif.dump
#   ./outils/local.sh migrer        applique les migrations et recharge les définitions
#   ./outils/local.sh compte        prépare le compte du coach avec local/demarrage.json
#   ./outils/local.sh scenarios S   rejoue les scénarios avec le vrai modèle
#   ./outils/local.sh appels        les derniers appels au modèle, outil par outil
#   ./outils/local.sh journal       les 200 dernières lignes de l'API
#   ./outils/local.sh etat          ce qui tourne
#   ./outils/local.sh arreter
#
# Chaque commande recopie sa sortie dans local/dernier.log. Le dossier local/
# n'est pas versionné : il garde la copie de la base, les clés et les rapports.

set -uo pipefail

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RACINE"
mkdir -p local
COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.local.yml)

lire_env() {
    local cle="$1" defaut="$2" valeur
    valeur="$(grep -m1 "^${cle}=" .env 2>/dev/null | cut -d= -f2- | tr -d "\"'" | tr -d '\r')"
    echo "${valeur:-$defaut}"
}
BASE="$(lire_env POSTGRES_DB planif)"
UTILISATEUR="$(lire_env POSTGRES_USER planif)"
PORT="$(lire_env API_PORT 8000)"

psql_local() { docker exec -i planif-db psql -U "$UTILISATEUR" -d "${1:-$BASE}" -v ON_ERROR_STOP=1 "${@:2}"; }

attendre_l_api() {
    for _ in $(seq 1 40); do
        if curl -fsS "http://localhost:${PORT}/sante" > /dev/null 2>&1; then
            echo "API prête : http://localhost:${PORT}/documentation"; return 0
        fi
        sleep 2
    done
    echo "L'API ne répond pas. Voir : ./outils/local.sh journal"; return 1
}

verifier_les_cles() {
    [ -f local/coach.env ] || { echo "local/coach.env manque."; return 1; }
    for cle in ANTHROPIC_API_KEY TELEGRAM_TOKEN; do
        if [ -z "$(grep -m1 "^${cle}=" local/coach.env | cut -d= -f2-)" ]; then
            echo "Attention : ${cle} est vide dans local/coach.env."
        fi
    done
}

commande="${1:-aide}"; shift || true

{
echo "=== $(date '+%d/%m/%Y %H:%M:%S') : local.sh ${commande} $*"
case "$commande" in
    demarrer)
        verifier_les_cles
        "${COMPOSE[@]}" up -d --build && attendre_l_api
        ;;
    arreter)
        "${COMPOSE[@]}" stop
        ;;
    restaurer)
        [ -f local/planif.dump ] || { echo "local/planif.dump manque."; exit 1; }
        echo "La base locale « ${BASE} » va être remplacée par la copie de production."
        "${COMPOSE[@]}" up -d db || exit 1
        "${COMPOSE[@]}" stop api
        sleep 3
        docker exec -i planif-db psql -U "$UTILISATEUR" -d postgres -v ON_ERROR_STOP=1 \
            -c "DROP DATABASE IF EXISTS ${BASE} WITH (FORCE)" -c "CREATE DATABASE ${BASE}" \
            || exit 1
        docker exec -i planif-db pg_restore -U "$UTILISATEUR" -d "$BASE" --no-owner \
            < local/planif.dump || exit 1
        # Une copie de production ne doit écrire à personne. Les comptes sont
        # déliés de Telegram : chacun se relie au bot de développement avec
        # /demarrer et sa clé. Ce qui attendait d'être envoyé est tenu pour envoyé.
        psql_local "$BASE" -q \
            -c "UPDATE utilisateur SET id_telegram = NULL" \
            -c "UPDATE notification SET statut = 'envoyee', date_envoi = now() WHERE statut = 'a_envoyer'" \
            || exit 1
        ./sql/appliquer.sh || exit 1
        "${COMPOSE[@]}" up -d --build api && attendre_l_api
        ;;
    migrer)
        ./sql/appliquer.sh
        ;;
    compte)
        fichier="${1:-local/demarrage.json}"
        [ -f "$fichier" ] || { echo "$fichier manque."; exit 1; }
        docker exec -i planif-api python -m outils.coach_demarrer < "$fichier"
        ;;
    scenarios)
        docker exec -i -e COACH_RAPPORT=/app/local/scenarios.md planif-api \
            python -m outils.coach_scenarios "$@"
        ;;
    appels)
        psql_local "$BASE" -P pager=off <<'SQL'
SELECT a.id_appel, to_char(a.debut AT TIME ZONE 'Europe/Paris', 'DD/MM HH24:MI') AS quand,
       a.moment, a.statut, a.essai, a.tours,
       round(EXTRACT(EPOCH FROM (a.fin - a.debut))) AS secondes,
       a.tokens_entree AS lus, a.tokens_cache AS cache, a.tokens_sortie AS ecrits,
       left(a.motif_echec, 60) AS echec
  FROM appel_coach a ORDER BY a.id_appel DESC LIMIT 15;
SELECT a.id_appel, d ->> 'tour' AS tour, d ->> 'outil' AS outil,
       CASE WHEN (d ->> 'refus')::BOOLEAN THEN 'REFUS' ELSE '' END AS refus,
       left(d ->> 'arguments', 90) AS arguments, left(d ->> 'resultat', 110) AS resultat
  FROM (SELECT * FROM appel_coach ORDER BY id_appel DESC LIMIT 3) a,
       jsonb_array_elements(a.deroule) d
 ORDER BY a.id_appel DESC, (d ->> 'tour')::INTEGER;
SQL
        ;;
    journal)
        docker logs --tail 200 planif-api 2>&1
        ;;
    etat)
        "${COMPOSE[@]}" ps
        curl -fsS "http://localhost:${PORT}/sante" || echo "L'API ne répond pas."
        echo
        ;;
    *)
        sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        ;;
esac
echo "=== fin (code $?)"
} 2>&1 | tee local/dernier.log
