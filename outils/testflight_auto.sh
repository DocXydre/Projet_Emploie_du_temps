#!/bin/sh
# Envoie l'appli à TestFlight quand ce qui a été poussé sur main change ios/.
#
#   ./outils/testflight_auto.sh installer     # une fois : l'agent launchd
#   ./outils/testflight_auto.sh desinstaller
#   ./outils/testflight_auto.sh               # un passage, ce que fait l'agent
#
# Le pendant de deployer.sh pour l'appli : ce Mac interroge GitHub toutes les
# cinq minutes au lieu d'être appelé. Rien ne part tant qu'il dort ou qu'il est
# éteint ; le push est rattrapé au réveil.
#
# La construction se fait dans un clone à part, jamais dans la copie de travail :
# seul ce qui est sur main part chez les testeurs, et un envoi en cours ne gêne
# pas Xcode. Ce qui est retenu, c'est l'arbre de ios/ envoyé avec succès : un
# push qui ne touche que le serveur ne produit pas de version.
#
# Un échec se dit dans une notification du Mac, une fois, et se réessaie tout
# seul.

set -e

ETAT="${HAL_TESTFLIGHT_ETAT:-$HOME/.local/state/hal-testflight}"
CLONE="$ETAT/depot"
TEMOIN="$ETAT/envoye"   # arbre de ios/ envoyé avec succès
ECHEC="$ETAT/echec"     # arbre de ios/ dont l'envoi a échoué
JOURNAL="$ETAT/dernier.log"
ATTENTE_MINUTES="${HAL_TESTFLIGHT_ATTENTE_MINUTES:-30}"
AGENT="fr.docxydre.hal.testflight"
PLIST="$HOME/Library/LaunchAgents/$AGENT.plist"
ICI="$(cd "$(dirname "$0")" && pwd)"

prevenir() {
    osascript -e "display notification \"$2\" with title \"$1\"" 2>/dev/null || true
}

installer() {
    mkdir -p "$ETAT" "$(dirname "$PLIST")"
    # L'adresse du serveur n'est pas dans le dépôt : le clone reprend celle de
    # cette copie de travail.
    if [ -f "$ICI/../ios/HAL/Serveur.local.xcconfig" ]; then
        cp "$ICI/../ios/HAL/Serveur.local.xcconfig" "$ETAT/"
    fi
    cat > "$PLIST" <<FIN
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$AGENT</string>
	<key>ProgramArguments</key>
	<array>
		<string>$ICI/testflight_auto.sh</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
	</dict>
	<key>StartInterval</key>
	<integer>300</integer>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardOutPath</key>
	<string>$ETAT/agent.log</string>
	<key>StandardErrorPath</key>
	<string>$ETAT/agent.log</string>
</dict>
</plist>
FIN
    launchctl bootout "gui/$(id -u)/$AGENT" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "Agent installé : un push sur main qui touche ios/ part à TestFlight."
    echo "Journal : $ETAT/agent.log et $JOURNAL"
}

case "${1:-}" in
    installer) installer; exit 0 ;;
    desinstaller)
        launchctl bootout "gui/$(id -u)/$AGENT" 2>/dev/null || true
        rm -f "$PLIST"
        echo "Agent retiré."
        exit 0 ;;
esac

mkdir -p "$ETAT"
if [ ! -d "$CLONE/.git" ]; then
    git clone --quiet "$(git -C "$ICI/.." remote get-url origin)" "$CLONE"
fi
cd "$CLONE"

git fetch --quiet origin main
DISTANT=$(git rev-parse origin/main)
ARBRE=$(git rev-parse "$DISTANT:ios")

[ "$(cat "$TEMOIN" 2>/dev/null || true)" = "$ARBRE" ] && exit 0

if [ "$(cat "$ECHEC" 2>/dev/null || true)" = "$ARBRE" ] \
   && [ -z "$(find "$ECHEC" -mmin "+$ATTENTE_MINUTES" 2>/dev/null)" ]; then
    exit 0
fi

COURT=$(git log -1 --format=%h "$DISTANT")
SUJET=$(git log -1 --format=%s "$DISTANT")
echo "$(date '+%F %T') Envoi de $COURT ($SUJET)"

git checkout --quiet --force "$DISTANT"
git clean --quiet -fdx
[ -f "$ETAT/Serveur.local.xcconfig" ] && cp "$ETAT/Serveur.local.xcconfig" ios/HAL/

if ./outils/testflight.sh > "$JOURNAL" 2>&1; then
    printf '%s\n' "$ARBRE" > "$TEMOIN"
    rm -f "$ECHEC"
    echo "$(date '+%F %T') Envoyé : $COURT"
    prevenir "HAL envoyé à TestFlight" "$SUJET"
    exit 0
fi

echo "$(date '+%F %T') Échec de $COURT, voir $JOURNAL"
if [ "$(cat "$ECHEC" 2>/dev/null || true)" != "$ARBRE" ]; then
    prevenir "Envoi TestFlight échoué" "$SUJET : voir $JOURNAL"
fi
printf '%s\n' "$ARBRE" > "$ECHEC"
exit 1
