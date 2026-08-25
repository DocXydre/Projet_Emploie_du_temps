#!/bin/sh
# Déploie ce qui a été poussé sur main, et rien d'autre.
#
# Appelé toutes les deux minutes par deployer-planif.timer. Le serveur
# interroge GitHub au lieu de recevoir un webhook : aucun port n'a besoin
# d'être ouvert, et un push fait machine éteinte est rattrapé au démarrage.
#
# Sortie silencieuse quand il n'y a rien à faire, pour garder un journal
# lisible.

set -e

DEPOT="${DEPOT:-$HOME/Projet_Emploie_du_temps}"
cd "$DEPOT"

git fetch --quiet origin main

LOCAL=$(git rev-parse HEAD)
DISTANT=$(git rev-parse origin/main)
[ "$LOCAL" = "$DISTANT" ] && exit 0

echo "Déploiement : $(git log --oneline -1 --format=%h origin/main) — $(git log -1 --format=%s origin/main)"

# --ff-only : le serveur ne doit jamais avoir de commit local. Si un fichier a
# été modifié sur place, le déploiement s'arrête au lieu de créer une fusion.
git merge --ff-only origin/main

# Les migrations avant le redémarrage : l'API appelle des fonctions SQL dès son
# démarrage, et se relancerait en boucle si elles n'existaient pas encore.
./sql/appliquer.sh

docker compose up -d --build api

echo "Déployé."
