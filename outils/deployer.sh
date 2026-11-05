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
COUPE_CIRCUIT="$ETAT/coupe_circuit"  # commit défait par un retour arrière, plus retenté seul
EN_PANNE="$ETAT/en_panne"     # le dernier déploiement a échoué : le prochain succès le dira
DESTINATAIRE="$ETAT/telegram" # à qui écrire, retenu tant que la base répond
JOURNAL="$ETAT/dernier.log"
SAUVEGARDES="${PLANIF_SAUVEGARDES:-$ETAT/sauvegardes}"
# Une par déploiement : trente couvrent largement les semaines où l'on pousse
# beaucoup, et la base tient en quelques mégaoctets.
SAUVEGARDES_GARDEES="${PLANIF_SAUVEGARDES_GARDEES:-30}"

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

# JRN-7 : inscrire le déploiement au journal de l'application, pour qu'il se lise
# à côté de ce qu'il a changé. Les textes passent en variables psql et non dans
# la requête : le sujet d'un commit peut contenir une apostrophe. Sans effet si
# la base ne répond pas, ou si le journal n'existe pas encore.
noter() {
    printf '%s\n' \
        "SELECT set_config('planif.acteur', 'deploiement', FALSE);" \
        "SELECT noter_evenement('deploiement', :'libelle', :'detail', TRUE);" \
    | docker exec -i "${PLANIF_CONTENEUR:-planif-db}" psql \
          --username="$(lire_env POSTGRES_USER)" --dbname="$(lire_env POSTGRES_DB)" \
          --quiet --set libelle="$1" --set detail="$2" > /dev/null 2>&1 || true
}

# Une copie de la base avant chaque migration. Une migration fautive poussée sur
# main part en production deux minutes plus tard : sans copie, ce qu'elle efface
# est perdu. Écrite à côté puis renommée, pour qu'une copie coupée en route ne
# passe jamais pour bonne. Les données sont personnelles : lisibles du seul
# compte du serveur.
#
# Pour revenir en arrière :
#   docker exec -i planif-db pg_restore -U planif -d planif --clean --if-exists \
#       < ~/.local/state/planif/sauvegardes/planif-….dump
sauvegarder() {
    ( umask 077 && mkdir -p "$SAUVEGARDES" ) || return 1
    copie="$SAUVEGARDES/planif-$(date +%Y%m%d-%H%M%S)-$COURT.dump"
    utilisateur="$(lire_env POSTGRES_USER)"
    base="$(lire_env POSTGRES_DB)"
    if ! ( umask 077 && docker exec "${PLANIF_CONTENEUR:-planif-db}" pg_dump \
               --username="${utilisateur:-planif}" --dbname="${base:-planif}" \
               --format=custom > "$copie.partielle" ) \
       || [ ! -s "$copie.partielle" ]; then
        rm -f "$copie.partielle"
        echo "Sauvegarde de la base impossible : rien n'est migré."
        return 1
    fi
    mv "$copie.partielle" "$copie"
    echo "Base sauvegardée : $copie"

    # Les plus anciennes s'en vont. Les noms ne contiennent pas d'espace.
    ls -1t "$SAUVEGARDES"/planif-*.dump | tail -n "+$((SAUVEGARDES_GARDEES + 1))" \
        | while read -r ancienne; do rm -f "$ancienne"; done
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

# Le coupe-circuit : un commit qui a déjà été défait par un retour arrière n'est
# plus jamais retenté seul. Il a cassé la production une fois ; le retenter
# toutes les quinze minutes la casserait autant de fois. Seul un nouveau commit,
# ou le retrait de ce fichier à la main, relance le déploiement.
if [ "$(cat "$COUPE_CIRCUIT" 2>/dev/null || true)" = "$DISTANT" ]; then
    exit 0
fi

COURT=$(git log -1 --format=%h "$DISTANT")
SUJET=$(git log -1 --format=%s "$DISTANT")
PRECEDENT=$(git rev-parse HEAD)
echo "Déploiement : $COURT, $SUJET"

# Ce que le déploiement a déjà changé, pour savoir quoi défaire s'il échoue :
# rien tant que la copie de la base n'est pas faite ; la base dès que les
# migrations commencent ; les conteneurs dès qu'ils sont reconstruits.
ETAPE="$ETAT/etape"
printf 'rien\n' > "$ETAPE"

# Les étapes s'enchaînent par « && », et non par `set -e` : dans le test
# d'un « if », le shell ignore `set -e` jusque dans les fonctions appelées, et
# une migration ratée n'aurait pas empêché la reconstruction de l'API.
deployer() {
    # --ff-only : le serveur ne doit jamais avoir de commit local. Si un
    # fichier a été modifié sur place, le déploiement s'arrête au lieu de créer
    # une fusion.
    git merge --ff-only "$DISTANT" &&
    printf 'code\n' > "$ETAPE" &&

    sauvegarder &&

    # Les migrations avant le redémarrage : l'API appelle des fonctions SQL dès
    # son démarrage, et se relancerait en boucle si elles n'existaient pas
    # encore.
    printf 'base\n' > "$ETAPE" &&
    ./sql/appliquer.sh &&

    # Les deux de la même image : l'API et le travailleur. La sonde de l'API
    # relaie celle du travailleur, et en_sante attend donc les deux.
    # PLANIF_COMMIT entre dans les conteneurs : /sante dit ainsi quel commit
    # tourne, ce que l'usine Uzine vérifie après un déploiement.
    printf 'conteneurs\n' > "$ETAPE" &&
    PLANIF_COMMIT="$DISTANT" docker compose up -d --build api travailleur &&

    en_sante
}

# Le retour arrière (méthode C du cahier d'Uzine) : la production revient à
# l'état d'avant le déploiement. Ce que le foyer a saisi pendant ces quelques
# minutes est perdu avec la restauration ; c'est accepté.
retour_arriere() {
    etape="$(cat "$ETAPE" 2>/dev/null || echo rien)"
    [ "$etape" = rien ] && return 0
    echo "Retour arrière vers $(git log -1 --format=%h "$PRECEDENT") (étape atteinte : $etape)."
    git reset --quiet --hard "$PRECEDENT" || return 1
    [ "$etape" = code ] && return 0

    # La base, depuis la copie faite juste avant les migrations. L'API et le
    # travailleur s'arrêtent le temps de la restauration : --clean ne peut pas
    # retirer ce qu'une connexion tient.
    docker compose stop api travailleur || true
    docker exec -i "${PLANIF_CONTENEUR:-planif-db}" pg_restore \
        --username="$(lire_env POSTGRES_USER)" --dbname="$(lire_env POSTGRES_DB)" \
        --clean --if-exists --single-transaction < "$copie" || return 1
    echo "Base restaurée depuis $copie"

    PLANIF_COMMIT="$PRECEDENT" docker compose up -d --build api travailleur && en_sante
}

if deployer > "$JOURNAL" 2>&1; then
    cat "$JOURNAL"
    printf '%s\n' "$DISTANT" > "$TEMOIN"
    rm -f "$ETAPE"
    retenir_destinataire
    noter "Déploiement de $COURT" "$SUJET"
    if [ -f "$EN_PANNE" ] || [ -f "$ECHEC" ] || [ -f "$COUPE_CIRCUIT" ]; then
        rm -f "$EN_PANNE" "$ECHEC" "$COUPE_CIRCUIT"
        prevenir "✅ Déploiement rétabli : $COURT, $SUJET"
    fi
    echo "Déployé."
    exit 0
fi

cat "$JOURNAL"
ETAPE_ATTEINTE="$(cat "$ETAPE" 2>/dev/null || echo rien)"
: > "$EN_PANNE"

# Rien n'a bougé en production : la fusion a échoué, ou la copie de la base, et
# rien n'a été migré. Le code est remis où il était, et l'ancien comportement
# s'applique : un nouvel essai après l'attente, une panne passagère se répare.
if [ "$ETAPE_ATTEINTE" = rien ] || [ "$ETAPE_ATTEINTE" = code ]; then
    retour_arriere >> "$JOURNAL" 2>&1 || true
    rm -f "$ETAPE"
    echo "Déploiement de $COURT échoué. Nouvel essai dans $ATTENTE_MINUTES minutes."
    if [ "$(cat "$ECHEC" 2>/dev/null || true)" != "$DISTANT" ]; then
        prevenir "⚠️ Déploiement raté : $COURT, $SUJET

$(tail -n 12 "$JOURNAL" | cut -c1-300)

Le serveur garde l'ancienne version et réessaie toutes les $ATTENTE_MINUTES minutes."
        noter "Déploiement raté de $COURT" "$SUJET"
    fi
    printf '%s\n' "$DISTANT" > "$ECHEC"
    exit 1
fi

# La production a bougé : on la remet comme avant, et on ne retente plus ce
# commit (coupe-circuit).
if retour_arriere >> "$JOURNAL" 2>&1; then
    BILAN="Retour arrière fait : la version d'avant tourne de nouveau$( [ "$ETAPE_ATTEINTE" = code ] || echo ", base restaurée")."
else
    BILAN="🚨 Retour arrière RATÉ : intervention à la main nécessaire (voir $JOURNAL)."
fi
rm -f "$ETAPE"
tail -n 4 "$JOURNAL"
echo "Déploiement de $COURT échoué. $BILAN Plus de nouvel essai automatique pour ce commit."
printf '%s\n' "$DISTANT" > "$COUPE_CIRCUIT"
rm -f "$ECHEC"
prevenir "⚠️ Déploiement raté : $COURT, $SUJET

$(sed -n '1,/^Retour arrière vers/p' "$JOURNAL" | tail -n 12 | cut -c1-300)

$BILAN
Ce commit ne sera plus retenté seul : pousse un correctif, ou retire $COUPE_CIRCUIT pour réessayer."
noter "Déploiement raté de $COURT, retour arrière" "$SUJET"
exit 1
