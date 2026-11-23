#!/bin/sh
# Tests for macos/scripts/appcast.sh (Sparkle's update feed).
# Run: scripts/tests/appcast_test.sh (or `make -C relay script-tests`).
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
appcast="$root/macos/scripts/appcast.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
url=https://github.com/tonimelisma/latchkey/releases/download/mac-0.8.231/Latchkey-0.8.231.zip
sig='QUJD+/ZGVm=='

if sh "$appcast" 0.8.231 "$url" 12345 "$sig" >"$work/feed.xml" 2>"$work/err"; then ok "writes a feed"; else bad "writes a feed"; fi
if python3 -c 'import sys, xml.etree.ElementTree as E; E.parse(sys.argv[1])' "$work/feed.xml" 2>/dev/null; then ok "the feed is well-formed XML"; else bad "the feed is well-formed XML"; fi
grep -q '<sparkle:version>8231</sparkle:version>' "$work/feed.xml" && ok "build number from the version" || bad "build number from the version"
grep -q '<sparkle:shortVersionString>0.8.231</sparkle:shortVersionString>' "$work/feed.xml" && ok "shows the version" || bad "shows the version"
grep -q "url=\"$url\" length=\"12345\"" "$work/feed.xml" && ok "names the archive and its length" || bad "names the archive and its length"
grep -q "sparkle:edSignature=\"$sig\"" "$work/feed.xml" && ok "carries the signature" || bad "carries the signature"
[ "$(grep -c '<item>' "$work/feed.xml")" = 1 ] && ok "only the newest release" || bad "only the newest release"

refused() {
  if sh "$appcast" "$@" >/dev/null 2>&1; then bad "refused: $*"; else ok "refused: $*"; fi
}
refused 0.8 "$url" 1 "$sig"
refused 0.8.1000 "$url" 1 "$sig"
refused 0.8.231 https://example.com/Latchkey.zip 1 "$sig"
refused 0.8.231 https://github.com/tonimelisma/latchkey/releases/download/mac-0.8.230/Latchkey.zip 1 "$sig"
refused 0.8.231 "$url" 12a "$sig"
refused 0.8.231 "$url" 1 'abc"/><x'
refused 0.8.231 "$url" 1 ''

[ "$fails" = 0 ] && echo "appcast_test: all passed"
exit "$fails"
