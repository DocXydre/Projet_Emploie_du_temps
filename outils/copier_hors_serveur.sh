#!/bin/sh
# Une copie de la base hors du serveur : sur le Mac, et chiffrée dans iCloud.
#
#   ./outils/copier_hors_serveur.sh            une copie maintenant
#   ./outils/copier_hors_serveur.sh installer  la programme chaque jour (launchd)
#
# Tourne sur le Mac, jamais sur le serveur. Le Mac va chercher : le serveur n'a
# ainsi ni accès au Mac ni identifiant d'un service en ligne. Par SSH, sur le
# réseau Tailscale, il demande au serveur un pg_dump frais, le vérifie, le garde
# dans ~/Sauvegardes/planif, puis en range une version chiffrée dans iCloud.
#
# Les copies que deployer.sh fait avant chaque migration restent sur le serveur :
# elles servent à défaire une migration. Celles-ci servent le jour où le serveur
# lui-même est perdu, et elles sont fraîches même quand rien n'a été poussé.
#
# Les réglages vivent dans ~/.config/planif/sauvegardes.env :
#
#   PLANIF_SERVEUR=thomas@serveur          ce qu'on tape après « ssh »
#   PLANIF_AGE_DESTINATAIRE=age1…          la clé publique qui chiffre la copie
#                                          d'iCloud (age-keygen, voir le README)
#
# et, s'ils diffèrent des valeurs par défaut :
#
#   POSTGRES_USER=planif  POSTGRES_DB=planif  PLANIF_CONTENEUR=planif-db
#   PLANIF_COPIES=~/Sauvegardes/planif        PLANIF_COPIES_GARDEES=30
#   PLANIF_ICLOUD=…/Sauvegardes planif
#
# Une copie réussie est inscrite au journal du serveur : la surveillance du
# travailleur prévient sur Telegram quand plus aucune n'arrive depuis trois jours.

set -eu

REGLAGES="${PLANIF_REGLAGES:-$HOME/.config/planif/sauvegardes.env}"
# shellcheck disable=SC1090
[ -f "$REGLAGES" ] && . "$REGLAGES"

SERVEUR="${PLANIF_SERVEUR:-}"
DESTINATAIRE="${PLANIF_AGE_DESTINATAIRE:-}"
UTILISATEUR="${POSTGRES_USER:-planif}"
BASE="${POSTGRES_DB:-planif}"
CONTENEUR="${PLANIF_CONTENEUR:-planif-db}"
COPIES="${PLANIF_COPIES:-$HOME/Sauvegardes/planif}"
GARDEES="${PLANIF_COPIES_GARDEES:-30}"
ICLOUD="${PLANIF_ICLOUD:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/Sauvegardes planif}"
ETIQUETTE="fr.docxydre.planif.sauvegardes"

# launchd ne donne qu'un PATH réduit : age et pg_restore viennent de Homebrew.
# Ajoutés après, pour ne pas passer devant ceux qu'on a déjà.
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/opt/homebrew/opt/postgresql@17/bin:/usr/local/opt/postgresql@17/bin"
export PATH

installer() {
    plist="$HOME/Library/LaunchAgents/$ETIQUETTE.plist"
    script="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
    # Tous les jours à 13 h. Mac endormi à cette heure : launchd rattrape le
    # passage manqué au réveil, une seule fois.
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$ETIQUETTE</string>
    <key>ProgramArguments</key>
    <array><string>/bin/sh</string><string>$script</string></array>
    <key>StartCalendarInterval</key>
    <dict><key>Hour</key><integer>13</integer><key>Minute</key><integer>0</integer></dict>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/planif-sauvegardes.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/planif-sauvegardes.log</string>
</dict>
</plist>
PLIST
    launchctl bootout "gui/$(id -u)/$ETIQUETTE" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$plist"
    echo "Programmé chaque jour à 13 h. Journal : ~/Library/Logs/planif-sauvegardes.log"
}

if [ "${1:-}" = "installer" ]; then
    installer
    exit 0
fi

[ -n "$SERVEUR" ] || { echo "PLANIF_SERVEUR manque dans $REGLAGES."; exit 1; }
[ -n "$DESTINATAIRE" ] || { echo "PLANIF_AGE_DESTINATAIRE manque dans $REGLAGES."; exit 1; }
command -v age > /dev/null || { echo "age manque : brew install age"; exit 1; }

echo "=== $(date '+%d/%m/%Y %H:%M:%S') : copie depuis $SERVEUR"

# Données de santé : lisibles du seul compte du Mac.
umask 077
mkdir -p "$COPIES" "$ICLOUD"

nom="planif-$(date +%Y%m%d-%H%M%S)"
copie="$COPIES/$nom.dump"

# Écrite à côté puis renommée : une copie coupée en route, réseau perdu ou Mac
# endormi, ne passe jamais pour bonne.
if ! ssh -o BatchMode=yes -o ConnectTimeout=20 "$SERVEUR" \
        "docker exec $CONTENEUR pg_dump --username=$UTILISATEUR --dbname=$BASE --format=custom" \
        > "$copie.partielle" \
   || [ ! -s "$copie.partielle" ]; then
    rm -f "$copie.partielle"
    echo "Le serveur n'a pas rendu de copie."
    exit 1
fi

# Une copie qu'on ne sait pas relire n'est pas une copie. pg_restore lit la
# table des matières sans rien restaurer.
if command -v pg_restore > /dev/null && ! pg_restore --list "$copie.partielle" > /dev/null; then
    rm -f "$copie.partielle"
    echo "La copie reçue est illisible : rien n'est gardé."
    exit 1
fi
mv "$copie.partielle" "$copie"
taille="$(du -h "$copie" | cut -f1 | tr -d ' ')"
echo "Sur le Mac : $copie ($taille)"

# iCloud ne voit que la version chiffrée : sans la clé privée, gardée hors
# d'iCloud, elle ne se lit pas.
#
# macOS laisse une tâche launchd écrire un fichier dans iCloud Drive, mais ni
# l'y renommer, ni lister le dossier, donc ni trier ni effacer les anciennes.
# D'où quatorze emplacements fixes, un par jour sur deux semaines : chaque
# copie écrase celle d'il y a quatorze jours (« planif-lundi-a », semaine
# paire, « planif-lundi-b », semaine impaire). Elle se chiffre à côté de la
# copie du Mac, puis se recopie. Une copie coupée en route ne se déchiffrerait
# pas : age vérifie chaque morceau.
jour="$(LC_ALL=C date +%u)"
set -- lundi mardi mercredi jeudi vendredi samedi dimanche
eval "jour=\${$jour}"
semaine="$(( $(date +%V | sed 's/^0*//') % 2 ))"
[ "$semaine" -eq 0 ] && moitie=a || moitie=b
chiffree="$ICLOUD/planif-$jour-$moitie.dump.age"
temporaire="$COPIES/.$nom.dump.age"
icloud=""
if age --recipient "$DESTINATAIRE" --output "$temporaire" "$copie" \
   && cp "$temporaire" "$chiffree"; then
    echo "Dans iCloud, chiffrée : $chiffree"
else
    rm -f "$chiffree" || true
    icloud=", sans iCloud"
    echo "La copie chiffrée n'est pas allée dans iCloud : seule celle du Mac est faite."
fi
rm -f "$temporaire"

# Sur le Mac, les plus anciennes s'en vont. Les noms ne contiennent pas d'espace.
( cd "$COPIES" && ls -1t planif-*.dump | tail -n "+$((GARDEES + 1))" \
    | while read -r ancienne; do rm -f "$ancienne"; done )

# Au journal du serveur : c'est ce que lit la surveillance (ADM-2). Le texte
# passe en variable psql, pas dans la requête.
printf '%s\n' \
    "SELECT set_config('planif.acteur', 'copie hors serveur', FALSE);" \
    "SELECT noter_evenement('sauvegarde_externe', :'libelle', NULL, TRUE);" \
  | ssh -o BatchMode=yes -o ConnectTimeout=20 "$SERVEUR" \
        "docker exec -i $CONTENEUR psql --username=$UTILISATEUR --dbname=$BASE --quiet --set libelle='Copie hors serveur, $taille$icloud' > /dev/null" \
  || echo "Copie faite, mais le serveur n'a pas pu la noter."

# Une copie sans iCloud se voit dans le journal de launchd.
[ -z "$icloud" ] || exit 1
echo "Fait."
