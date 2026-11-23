#!/bin/sh
# Builds the installable disk image: build/Latchkey-<version>.dmg with the app and a link to
# Applications. Release configuration, signed with the team in Config/Local.xcconfig.
# Until a Developer ID exists the app is signed for development and not notarized: another Mac
# opens it after Privacy & Security → Open Anyway (scripts/publish.sh puts it on GitHub).
# One image for everyone: it carries no relay address (LATCHKEY_DEFAULT_RELAY_HOST is emptied
# here), so setup asks for the relay; the installed app is already paired.
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
# Sparkle compares the build number (CFBundleVersion): x*1000000 + y*1000 + z of x.y.z, so it
# grows with every release (Updates.swift, UpdateGate.buildNumber, keeps the same rule).
BUILD=$(printf '%s\n' "$VERSION" | awk -F. 'NF == 3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $2 < 1000 && $3 < 1000 { printf "%d", $1 * 1000000 + $2 * 1000 + $3 }')
[ -n "$BUILD" ] || {
  echo "package: version $VERSION isn't x.y.z with y and z below 1000" >&2
  exit 1
}
OUT=build/package
rm -rf "$OUT"
mkdir -p "$OUT/stage"

xcodegen generate --quiet
# Fresh products: an incremental build once kept a stale, differently signed helper copy inside
# the app. XCODEBUILD_SIGNING: extra build settings for signing, words without spaces (CI's
# release job signs with a certificate it imported: CODE_SIGN_STYLE=Manual
# CODE_SIGN_IDENTITY=<its SHA-1>); empty on the Mac, which signs as Xcode is set up.
rm -rf build/DerivedData/Build/Products/Release
# shellcheck disable=SC2086 # XCODEBUILD_SIGNING is split into its words on purpose
xcodebuild -project Latchkey.xcodeproj -scheme Latchkey -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  LATCHKEY_DEFAULT_RELAY_HOST= ${XCODEBUILD_SIGNING:-} build -quiet
APP=build/DerivedData/Build/Products/Release/Latchkey.app

codesign --verify --deep --strict "$APP"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" = "$BUILD" ] || {
  echo "package: the app's build number isn't $BUILD" >&2
  exit 1
}
[ -z "$(/usr/libexec/PlistBuddy -c 'Print :LatchkeyDefaultRelayHost' "$APP/Contents/Info.plist" 2>/dev/null)" ] || {
  echo "package: the app carries a default relay address" >&2
  exit 1
}
test -x "$APP/Contents/MacOS/LatchkeyHelper"
plutil -lint -s "$APP/Contents/Library/LaunchDaemons/net.melisma.latchkey.helper.plist"
codesign -d -r- "$APP/Contents/MacOS/LatchkeyHelper" 2>&1 | grep -q 'identifier "net.melisma.latchkey.helper"'
# Shell's test launcher (spec 004 FR-335), signed as the app's own.
test -x "$APP/Contents/MacOS/LatchkeyXcodeTests"
codesign -d -r- "$APP/Contents/MacOS/LatchkeyXcodeTests" 2>&1 | grep -q 'identifier "net.melisma.latchkey.xcodetests"'
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
