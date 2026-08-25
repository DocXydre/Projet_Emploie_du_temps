#!/bin/sh
# Déploie ce qui a été poussé sur main, et rien d'autre.
#
# Appelé toutes les deux minutes par deployer-planif.timer. Interroger GitHub
# plutôt que d'attendre un webhook évite d'exposer quoi que ce soit : le
# serveur n'a aucun port ouvert, et un push fait pendant qu'il était éteint est
# rattrapé au démarrage suivant.
#
# Le script sort en silence quand il n'y a rien à faire, ce qui est le cas la
# quasi-totalité du temps : sans cela, le journal serait illisible.

set -e

DEPOT="${DEPOT:-$HOME/Projet_Emploie_du_temps}"
cd "$DEPOT"

git fetch --quiet origin main

LOCAL=$(git rev-parse HEAD)
DISTANT=$(git rev-parse origin/main)
[ "$LOCAL" = "$DISTANT" ] && exit 0

echo "Déploiement : $(git log --oneline -1 --format=%h origin/main) — $(git log -1 --format=%s origin/main)"

# --ff-only et non merge : le serveur ne doit jamais avoir de commit à lui.
# Si quelqu'un a bricolé un fichier ici, autant que le déploiement s'arrête et
# le dise, plutôt que de fabriquer une fusion que personne ne relira.
git merge --ff-only origin/main

# Les migrations avant le redémarrage : l'API appelle des fonctions SQL dès son
# démarrage, et se relancerait en boucle si elles n'existaient pas encore.
./sql/appliquer.sh

docker compose up -d --build api

echo "Déployé."
