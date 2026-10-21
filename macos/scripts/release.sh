#!/bin/sh
# Builds, signs, notarizes, and publishes a Latchkey release (FR-072, plan D9):
#   scripts/release.sh 0.1.0
#
# One-time setup (Toni):
#   1. Developer ID: the "Developer ID Application" certificate in Xcode → Settings → Accounts.
#   2. Notarization profile:
#        xcrun notarytool store-credentials latchkey-notary --apple-id <id> --team-id <team>
#   3. Update signing key (Sparkle EdDSA; the private key stays in your login keychain):
#        build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
#      and put the printed public key in Config/Base.xcconfig as SPARKLE_PUBLIC_ED_KEY.
#   4. The repository must be public, so the update feed and downloads need no login.
#   5. gh auth login
set -eu
VERSION=${1:?usage: scripts/release.sh <version>}
cd "$(dirname "$0")/.."
OUT=build/release/$VERSION
SPARKLE_BIN=build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin
rm -rf "$OUT"
mkdir -p "$OUT"

grep -q '^SPARKLE_PUBLIC_ED_KEY = .\+' Config/Base.xcconfig || { echo "Set SPARKLE_PUBLIC_ED_KEY first (step 3)."; exit 1; }

xcodegen generate --quiet
xcodebuild -project Latchkey.xcodeproj -scheme Latchkey -configuration Release \
  -derivedDataPath build/DerivedData -archivePath "$OUT/Latchkey.xcarchive" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M)" archive -quiet
xcodebuild -exportArchive -archivePath "$OUT/Latchkey.xcarchive" -exportPath "$OUT" \
  -exportOptionsPlist scripts/ExportOptions.plist -quiet

ditto -c -k --keepParent "$OUT/Latchkey.app" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile latchkey-notary --wait
xcrun stapler staple "$OUT/Latchkey.app"
spctl --assess --type execute --verbose "$OUT/Latchkey.app"

ZIP="$OUT/Latchkey-$VERSION.zip"
ditto -c -k --keepParent "$OUT/Latchkey.app" "$ZIP"
mkdir -p "$OUT/feed"
cp "$ZIP" "$OUT/feed/"
"$SPARKLE_BIN/generate_appcast" --download-url-prefix \
  "https://github.com/tonimelisma/latchkey/releases/download/v$VERSION/" "$OUT/feed"

gh release create "v$VERSION" "$ZIP" "$OUT/feed/appcast.xml" --title "Latchkey $VERSION" --generate-notes
echo "Released v$VERSION"
