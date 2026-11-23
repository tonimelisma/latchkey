#!/bin/sh
# Writes Sparkle's update feed for one Mac release (spec 001 FR-072, FR-072c) to standard output:
#   scripts/appcast.sh <version x.y.z> <archive URL> <archive length> <EdDSA signature>
# The feed holds only the newest release: Sparkle needs nothing older, and older releases are
# deleted (publish.sh keeps three). The build number follows package.sh's rule. The app reads it
# from https://github.com/tonimelisma/latchkey/releases/latest/download/appcast.xml (Info.plist,
# SUFeedURL); the Mac release is the one marked latest. Tested by scripts/tests/appcast_test.sh.
set -eu
VERSION=${1:?usage: appcast.sh <version> <url> <length> <signature>}
URL=${2:?archive URL}
LENGTH=${3:?archive length}
SIGNATURE=${4:?EdDSA signature}
BUILD=$(printf '%s\n' "$VERSION" | awk -F. 'NF == 3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $2 < 1000 && $3 < 1000 { printf "%d", $1 * 1000000 + $2 * 1000 + $3 }')
[ -n "$BUILD" ] || { echo "appcast: version $VERSION isn't x.y.z with y and z below 1000" >&2; exit 1; }
case $LENGTH in '' | *[!0-9]*) echo "appcast: length $LENGTH isn't a number" >&2; exit 1 ;; esac
case $URL in https://github.com/tonimelisma/latchkey/releases/download/mac-"$VERSION"/*) ;; *)
  echo "appcast: the archive isn't in the release mac-$VERSION on GitHub" >&2
  exit 1
  ;;
esac
# A signature is base64: nothing in it needs escaping in XML, and anything else is refused.
case $SIGNATURE in '' | *[!A-Za-z0-9+/=]*) echo "appcast: the signature isn't base64" >&2; exit 1 ;; esac
DATE=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')
cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Latchkey</title>
    <item>
      <title>Latchkey $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <enclosure url="$URL" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
    </item>
  </channel>
</rss>
EOF
