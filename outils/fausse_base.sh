#!/usr/bin/env bash
# La fausse base, pour vérifier l'appli HAL dans le simulateur.
#
#   ./outils/fausse_base.sh          crée ou refait la base de zéro, puis lance l'API dessus
#   ./outils/fausse_base.sh migrer   rejoue seulement les migrations sur la fausse base
#
# Une base à part, « planif_maquette », dans le même conteneur que la base
# locale. Elle ne lit jamais local/planif.dump et n'y touche pas : la vraie base
# locale, avec ses données de santé, reste telle quelle.
#
# Tout ce qu'elle contient est inventé (outils/fausse_base.py). Les dates
# partent d'aujourd'hui : relancer le script le lendemain refait une base à jour.
#
# L'API tourne ensuite sur cette base, sans ordonnanceur ni bot
# (docker-compose.maquette.yml) : aucune notification, aucun appel payant au
# modèle ne part tout seul. Les comptes :
#
#   thomas   / maquette-thomas      administrateur, HAL démarré
#   lorette  / maquette-lorette     HAL pas démarré
#
# Dans l'appli, l'adresse du serveur est http://localhost:8000.
#
# Pour revenir à la base locale habituelle : ./outils/local.sh demarrer

set -euo pipefail

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RACINE"
BASE=planif_maquette
COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.local.yml
         -f docker-compose.maquette.yml)

UTILISATEUR="$(grep -m1 '^POSTGRES_USER=' .env 2>/dev/null | cut -d= -f2- | tr -d "\"'\r")"
UTILISATEUR="${UTILISATEUR:-planif}"
PORT="$(grep -m1 '^API_PORT=' .env 2>/dev/null | cut -d= -f2- | tr -d "\"'\r")"
PORT="${PORT:-8000}"

migrer() { PLANIF_BASE="$BASE" ./sql/appliquer.sh | tail -4; }

if [ "${1:-}" = "migrer" ]; then
    migrer
    exit 0
fi

"${COMPOSE[@]}" up -d db
for _ in $(seq 1 30); do
    docker exec planif-db pg_isready -U "$UTILISATEUR" > /dev/null 2>&1 && break
    sleep 1
done

# CNX-11 : les sessions ouvertes dans le simulateur survivent à la base refaite,
# pour que l'appli y reste connectée. Rien à garder au tout premier passage.
SESSIONS="$(docker exec planif-db psql -U "$UTILISATEUR" -d "$BASE" -tAq -c \
    "SELECT string_agg(format('(%L, %L, %L)', u.pseudo, s.empreinte, s.nom), ',')
       FROM session_appareil s JOIN utilisateur u USING (id_utilisateur)
      WHERE s.revoquee_le IS NULL" 2>/dev/null || true)"

# L'API lâche la base avant qu'on la refasse. Le travailleur s'arrête aussi :
# laissé par ./outils/local.sh, il enverrait des notifications depuis la base
# locale pendant qu'on regarde la maquette.
"${COMPOSE[@]}" stop api travailleur > /dev/null 2>&1 || true
docker exec -i planif-db psql -U "$UTILISATEUR" -d postgres -v ON_ERROR_STOP=1 -q \
    -c "DROP DATABASE IF EXISTS ${BASE} WITH (FORCE)" -c "CREATE DATABASE ${BASE}"
echo "Base ${BASE} neuve. Migrations :"
migrer

# Le remplissage, dans un conteneur de l'API à part : l'API elle-même ne
# démarre qu'après, pour que son amorçage trouve les sources déjà remplies.
echo
echo "Remplissage :"
"${COMPOSE[@]}" run --rm --no-deps -T api python -m outils.fausse_base

if [ -n "$SESSIONS" ]; then
    docker exec -i planif-db psql -U "$UTILISATEUR" -d "$BASE" -v ON_ERROR_STOP=1 -q -c \
        "INSERT INTO session_appareil (id_utilisateur, empreinte, nom)
         SELECT u.id_utilisateur, v.empreinte, v.nom
           FROM (VALUES $SESSIONS) AS v (pseudo, empreinte, nom)
           JOIN utilisateur u ON u.pseudo = v.pseudo"
fi

"${COMPOSE[@]}" up -d --build api
for _ in $(seq 1 40); do
    if curl -fsS "http://localhost:${PORT}/sante" > /dev/null 2>&1; then
        echo
        echo "API prête sur la fausse base : http://localhost:${PORT}"
        exit 0
    fi
    sleep 2
done
echo "L'API ne répond pas. Voir : ./outils/local.sh journal"
exit 1
