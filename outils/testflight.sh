#!/bin/sh
# Envoie l'appli HAL à TestFlight : régénère le projet, archive, signe pour la
# distribution et dépose la version sur App Store Connect.
#
#   ./outils/testflight.sh
#
# Il faut, sur ce Mac, le compte de l'équipe payante (DEVELOPMENT_TEAM de
# project.yml) dans Xcode, Réglages, Comptes, et la fiche de l'appli créée une
# fois sur App Store Connect avec l'identifiant fr.docxydre.hal.
#
# Il faut aussi un certificat « Apple Distribution » dans le trousseau de ce Mac
# (Xcode, Réglages, Comptes, Manage Certificates, +). Sans lui, Xcode signe avec
# le certificat gardé chez Apple, et sa signature à distance écrit le « ü » de
# « Kühn » décomposé : Apple refuse alors l'envoi (« Invalid Signature », 90035).
#
# Le numéro de version (CFBundleVersion) est la date et l'heure de l'envoi :
# il monte tout seul, Apple refuse deux envois avec le même. La version affichée
# (MARKETING_VERSION) reste celle de project.yml.
#
# L'adresse du serveur intégrée vient de Serveur.local.xcconfig, comme pour une
# installation depuis Xcode : sans lui, l'appli demandera l'adresse.

set -e

RACINE="$(cd "$(dirname "$0")/.." && pwd)"
IOS="$RACINE/ios/HAL"
NUMERO="$(date +%Y%m%d.%H%M)"
# L'archive va là où Xcode range les siennes : elle se retrouve dans
# Window, Organizer, d'où l'on peut aussi la renvoyer à la main.
ARCHIVE="$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)/HAL $NUMERO.xcarchive"
SORTIE="$(mktemp -d)"
EQUIPE="$(sed -n 's/^ *DEVELOPMENT_TEAM: *//p' "$IOS/project.yml" | head -1)"

[ -f "$IOS/Serveur.local.xcconfig" ] || echo "Attention : pas de Serveur.local.xcconfig, l'appli demandera l'adresse du serveur."

cd "$IOS"
xcodegen -q

mkdir -p "$(dirname "$ARCHIVE")"

cat > "$SORTIE/ExportOptions.plist" <<FIN
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>teamID</key>
	<string>$EQUIPE</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>signingCertificate</key>
	<string>Apple Distribution</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
	<key>testFlightInternalTestingOnly</key>
	<false/>
</dict>
</plist>
FIN

echo "Archive de HAL, version $NUMERO..."
xcodebuild archive \
  -project HAL.xcodeproj -scheme HAL \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$NUMERO" \
  -quiet

echo "Envoi à App Store Connect..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$SORTIE/ExportOptions.plist" \
  -exportPath "$SORTIE/export" \
  -allowProvisioningUpdates

echo "Envoyé : version $NUMERO. Elle apparaît dans TestFlight après le traitement d'Apple (quelques minutes)."
