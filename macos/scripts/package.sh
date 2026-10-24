#!/bin/sh
# Builds the installable disk image: build/Latchkey-<version>.dmg with the app and a link to
# Applications. Release configuration, signed with the team in Config/Local.xcconfig.
# Until a Developer ID exists the app is signed for development and not notarized: it installs
# and runs on Macs registered to the team (this Mac), not on others (see scripts/release.sh).
set -eu
cd "$(dirname "$0")/.."
../scripts/link-local-files.sh
grep -q '^ *DEVELOPMENT_TEAM *= *[A-Z0-9]' Config/Local.xcconfig 2>/dev/null || {
  echo "package: Config/Local.xcconfig with DEVELOPMENT_TEAM is missing; a build signed otherwise would lose the installed app's permissions and pairing" >&2
  exit 1
}
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)
OUT=build/package
rm -rf "$OUT"
mkdir -p "$OUT/stage"

xcodegen generate --quiet
xcodebuild -project Latchkey.xcodeproj -scheme Latchkey -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData build -quiet
APP=build/DerivedData/Build/Products/Release/Latchkey.app

codesign --verify --deep --strict "$APP"
test -x "$APP/Contents/MacOS/LatchkeyHelper"
plutil -lint -s "$APP/Contents/Library/LaunchDaemons/net.melisma.latchkey.helper.plist"
codesign -d -r- "$APP/Contents/MacOS/LatchkeyHelper" 2>&1 | grep -q 'identifier "net.melisma.latchkey.helper"'

ditto "$APP" "$OUT/stage/Latchkey.app"
ln -s /Applications "$OUT/stage/Applications"
DMG=build/Latchkey-$VERSION.dmg
rm -f "$DMG"
hdiutil create -quiet -volname "Latchkey $VERSION" -srcfolder "$OUT/stage" -fs HFS+ -format UDZO "$DMG"
hdiutil verify -quiet "$DMG"
rm -rf "$OUT"
echo "$DMG"
