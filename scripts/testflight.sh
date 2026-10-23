#!/bin/sh
# Builds an archive and exports it for App Store Connect; with --upload it also
# sends the build to TestFlight. Signing happens at export, with the team from
# Config/Signing.local.xcconfig and the Apple account signed in to Xcode, so no
# registered device is needed. Bump CURRENT_PROJECT_VERSION before every upload.
set -eu
cd "$(dirname "$0")/.."

team=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Config/Signing.local.xcconfig 2>/dev/null)
[ -n "$team" ] || { echo "Set DEVELOPMENT_TEAM in Config/Signing.local.xcconfig" >&2; exit 1; }

# The production relay's API key and the iOS app's Firebase app ID stay out of
# the repository. They come from the environment or from a file outside it
# (Config/relay.env.example shows its shape) and land in a Swift file that git
# ignores; a release build without that file does not compile.
relay_env=${SNOTRA_RELAY_ENV:-$HOME/env/snotra-mobile/relay.env}
relay_setting() { sed -n "s/^$1 *= *//p" "$relay_env" 2>/dev/null | tail -n 1; }
api_key=${SNOTRA_RELAY_API_KEY:-$(relay_setting SNOTRA_RELAY_API_KEY)}
app_id=${SNOTRA_FIREBASE_APP_ID:-$(relay_setting SNOTRA_FIREBASE_APP_ID)}
if ! printf '%s' "$api_key" | grep -Eq '^[A-Za-z0-9_-]+$' ||
   ! printf '%s' "$app_id" | grep -Eq '^1:[0-9]+:ios:[0-9a-f]+$'; then
  echo "The production relay's configuration is missing or malformed: set SNOTRA_RELAY_API_KEY" >&2
  echo "and SNOTRA_FIREBASE_APP_ID (1:<project number>:ios:<hash>) in $relay_env" >&2
  echo "(see Config/relay.env.example), or in the environment." >&2
  exit 1
fi
cat > SnotraMobile/Relay/ProductionRelay.local.swift <<SWIFT
// Written by scripts/testflight.sh; git ignores this file. See RelayEndpoint.builtIn.
enum ProductionRelayConfiguration {
    static let apiKey = "$api_key"
    static let firebaseAppId = "$app_id"
}
SWIFT

destination=export
[ "${1:-}" = "--upload" ] && destination=upload

out=build/testflight
rm -rf "$out"
mkdir -p "$out"

cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$destination</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$team</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

xcodebuild archive -project SnotraMobile.xcodeproj -scheme SnotraMobile \
  -destination 'generic/platform=iOS' -archivePath "$out/SnotraMobile.xcarchive" \
  CODE_SIGNING_ALLOWED=NO

xcodebuild -exportArchive -archivePath "$out/SnotraMobile.xcarchive" \
  -exportOptionsPlist "$out/ExportOptions.plist" -exportPath "$out" \
  -allowProvisioningUpdates
