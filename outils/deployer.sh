#!/bin/sh
# Déploie ce qui a été poussé sur main, et rien d'autre.
#
# Appelé toutes les deux minutes par deployer-planif.timer. Le serveur
# interroge GitHub au lieu de recevoir un webhook : aucun port n'a besoin
# d'être ouvert, et un push fait machine éteinte est rattrapé au démarrage.
#
# Sortie silencieuse quand il n'y a rien à faire, pour garder un journal
# lisible.
#
# Ce que le script retient, c'est le dernier commit déployé avec succès, et non
# celui que git a sous les yeux. La différence compte. Avant, il comparait HEAD
# à origin/main : une migration qui échouait après la fusion laissait HEAD à
# jour, et le passage suivant concluait qu'il n'y avait plus rien à faire. Le
# serveur restait alors sur l'ancienne API avec une base à moitié migrée, sans
# que personne ne le sache.
#
# Un échec se dit maintenant sur Telegram, une fois, et se réessaie tout seul.

set -e

DEPOT="${DEPOT:-$HOME/Projet_Emploie_du_temps}"
ETAT="${PLANIF_ETAT:-$HOME/.local/state/planif}"
# Entre deux essais d'un déploiement qui échoue. Assez court pour qu'une panne
# passagère se répare seule, assez long pour ne pas reconstruire l'image toutes
# les deux minutes.
ATTENTE_MINUTES="${PLANIF_ATTENTE_MINUTES:-15}"

cd "$DEPOT"
mkdir -p "$ETAT"

TEMOIN="$ETAT/deploye"        # dernier commit déployé avec succès
ECHEC="$ETAT/echec"           # commit dont le déploiement a échoué
DESTINATAIRE="$ETAT/telegram" # à qui écrire, retenu tant que la base répond
JOURNAL="$ETAT/dernier.log"

# Lecture littérale d'une variable du .env, comme dans appliquer.sh : le fichier
# contient des URL que le shell ne sait pas sourcer.
lire_env() {
    [ -f "$DEPOT/.env" ] || return 0
    grep -m1 "^$1=" "$DEPOT/.env" | cut -d= -f2- | tr -d "\"'" | tr -d '\r'
}

# Prévenir sur Telegram, directement. Passer par l'API ou par la base serait
# compter sur ce qui vient justement de tomber.
prevenir() {
    # Pas encore de destinataire retenu : c'est le cas au tout premier passage.
    # On le demande à la base, qui répond le plus souvent même quand le
    # déploiement échoue.
    [ -s "$DESTINATAIRE" ] || retenir_destinataire
    jeton="$(lire_env TELEGRAM_TOKEN)"
    [ -n "$jeton" ] && [ -s "$DESTINATAIRE" ] || return 0
    curl --silent --show-error --max-time 20 --output /dev/null \
         "https://api.telegram.org/bot${jeton}/sendMessage" \
         --data-urlencode "chat_id=$(cat "$DESTINATAIRE")" \
         --data-urlencode "text=$1" || true
}

# L'administrateur, tel que la base le connaît. Relevé à chaque succès pour
# l'avoir encore sous la main le jour où la base ne répond plus.
retenir_destinataire() {
    qui="$(docker exec -i "${PLANIF_CONTENEUR:-planif-db}" psql \
              --username="$(lire_env POSTGRES_USER)" --dbname="$(lire_env POSTGRES_DB)" \
              --tuples-only --no-align --command \
              "SELECT id_telegram FROM utilisateur
                WHERE role = 'admin' AND actif AND id_telegram IS NOT NULL
                ORDER BY id_utilisateur LIMIT 1" 2>/dev/null || true)"
    [ -n "$qui" ] && printf '%s\n' "$qui" > "$DESTINATAIRE"
    return 0
}

# L'API répond-elle, base comprise ? `docker compose up` rend la main dès que le
# conteneur est lancé : une API qui tombe au démarrage, faute d'une fonction SQL
# par exemple, passerait sinon pour un déploiement réussi.
en_sante() {
    port="$(lire_env API_PORT)"
    # L'API n'écoute que sur l'adresse donnée par API_BIND, la boucle locale
    # par défaut. La sonde doit frapper à la même porte.
    hote="$(lire_env API_BIND)"
    case "$hote" in ""|0.0.0.0) hote=127.0.0.1 ;; esac
    essais=0
    while [ "$essais" -lt "${PLANIF_ESSAIS_SANTE:-30}" ]; do
        if curl --silent --fail --max-time 5 "http://${hote}:${port:-8000}/sante" \
             | grep -q '"etat": *"ok"'; then
            return 0
        fi
        essais=$((essais + 1))
        sleep "${PLANIF_PAUSE_SANTE:-3}"
    done
    echo "L'API ne répond pas correctement sur /sante après le redémarrage."
    docker compose logs --tail=15 api 2>&1 || true
    return 1
}

git fetch --quiet origin main

DISTANT=$(git rev-parse origin/main)
DEPLOYE=$(cat "$TEMOIN" 2>/dev/null || true)
[ "$DEPLOYE" = "$DISTANT" ] && exit 0

# Un commit qui a déjà échoué n'est réessayé qu'après l'attente. Un nouveau
# commit, lui, part tout de suite : c'est peut-être le correctif.
if [ "$(cat "$ECHEC" 2>/dev/null || true)" = "$DISTANT" ] \
   && [ -z "$(find "$ECHEC" -mmin "+$ATTENTE_MINUTES" 2>/dev/null)" ]; then
    exit 0
fi

COURT=$(git log -1 --format=%h "$DISTANT")
SUJET=$(git log -1 --format=%s "$DISTANT")
echo "Déploiement : $COURT, $SUJET"

# Les trois étapes s'enchaînent par « && », et non par `set -e` : dans le test
# d'un « if », le shell ignore `set -e` jusque dans les fonctions appelées, et
# une migration ratée n'aurait pas empêché la reconstruction de l'API.
deployer() {
    # --ff-only : le serveur ne doit jamais avoir de commit local. Si un
    # fichier a été modifié sur place, le déploiement s'arrête au lieu de créer
    # une fusion.
    git merge --ff-only "$DISTANT" &&

    # Les migrations avant le redémarrage : l'API appelle des fonctions SQL dès
    # son démarrage, et se relancerait en boucle si elles n'existaient pas
    # encore.
    ./sql/appliquer.sh &&

    docker compose up -d --build api &&

    en_sante
}

if deployer > "$JOURNAL" 2>&1; then
    cat "$JOURNAL"
    printf '%s\n' "$DISTANT" > "$TEMOIN"
    retenir_destinataire
    if [ -f "$ECHEC" ]; then
        rm -f "$ECHEC"
        prevenir "✅ Déploiement rétabli : $COURT, $SUJET"
    fi
    echo "Déployé."
    exit 0
fi

cat "$JOURNAL"
echo "Déploiement de $COURT échoué. Nouvel essai dans $ATTENTE_MINUTES minutes."

# Une seule alerte par commit : les essais suivants se taisent, sinon un
# déploiement cassé un vendredi soir ferait vibrer le téléphone tout le week-end.
if [ "$(cat "$ECHEC" 2>/dev/null || true)" != "$DISTANT" ]; then
    prevenir "⚠️ Déploiement raté : $COURT, $SUJET

$(tail -n 12 "$JOURNAL" | cut -c1-300)

Le serveur garde l'ancienne version et réessaie toutes les $ATTENTE_MINUTES minutes."
fi
printf '%s\n' "$DISTANT" > "$ECHEC"
exit 1
