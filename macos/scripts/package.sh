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
# The version comes from the release tag (install.sh passes it); a commit already released keeps
# its tag's number.
VERSION=${VERSION:-$(git describe --tags --exact-match --match 'mac-[0-9]*' HEAD 2>/dev/null | sed 's/^mac-//')}
[ -n "$VERSION" ] || {
  echo "package: this commit has no release tag mac-<x.y.z>; make install gives it one" >&2
  exit 1
}
OUT=build/package
rm -rf "$OUT"
mkdir -p "$OUT/stage"

xcodegen generate --quiet
# Fresh products: an incremental build once kept a stale, differently signed helper copy inside
# the app.
rm -rf build/DerivedData/Build/Products/Release
xcodebuild -project Latchkey.xcodeproj -scheme Latchkey -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData MARKETING_VERSION="$VERSION" build -quiet
APP=build/DerivedData/Build/Products/Release/Latchkey.app

codesign --verify --deep --strict "$APP"
test -x "$APP/Contents/MacOS/LatchkeyHelper"
plutil -lint -s "$APP/Contents/Library/LaunchDaemons/net.melisma.latchkey.helper.plist"
codesign -d -r- "$APP/Contents/MacOS/LatchkeyHelper" 2>&1 | grep -q 'identifier "net.melisma.latchkey.helper"'
# No signed code in the app may carry the debugging entitlement: with it, any program running as
# the Owner can take over the app's process and use its privacy permissions (security scan,
# 2026-10-24). Release builds don't inject it (project.yml); this keeps it that way.
find "$APP" -type f -perm -u+x | while read -r bin; do
  if codesign -d --entitlements - --xml "$bin" 2>/dev/null | grep -q 'com.apple.security.get-task-allow'; then
    echo "package: $bin is signed with com.apple.security.get-task-allow" >&2
    exit 1
  fi
done

ditto "$APP" "$OUT/stage/Latchkey.app"
ln -s /Applications "$OUT/stage/Applications"
DMG=build/Latchkey-$VERSION.dmg
rm -f "$DMG"
hdiutil create -quiet -volname "Latchkey $VERSION" -srcfolder "$OUT/stage" -fs HFS+ -format UDZO "$DMG"
hdiutil verify -quiet "$DMG"
rm -rf "$OUT"
echo "$DMG"
