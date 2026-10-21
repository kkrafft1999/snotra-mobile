#!/bin/sh
# Builds an archive and exports it for App Store Connect; with --upload it also
# sends the build to TestFlight. Signing happens at export, with the team from
# Config/Signing.local.xcconfig and the Apple account signed in to Xcode, so no
# registered device is needed. Bump CURRENT_PROJECT_VERSION before every upload.
set -eu
cd "$(dirname "$0")/.."

team=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Config/Signing.local.xcconfig 2>/dev/null)
[ -n "$team" ] || { echo "Set DEVELOPMENT_TEAM in Config/Signing.local.xcconfig" >&2; exit 1; }

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
