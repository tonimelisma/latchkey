#!/bin/sh
# Installs the newest build/Latchkey-<version>.dmg into /Applications and starts it, as the Owner
# would by dragging it there (Toni, 2026-10-23: every increment installs itself). Quits the
# running app cleanly first (SIGTERM: it says goodbye to the relay and restores sleep), swaps the
# app in place, removes the old copy, opens the new one, and checks it started. Permissions and the
# pairing carry over: same signature, same settings and Keychain.
set -eu
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)
DMG=build/Latchkey-$VERSION.dmg
[ -f "$DMG" ] || { echo "install: $DMG not found; run make dmg" >&2; exit 1; }
DEST=/Applications/Latchkey.app
OLD=/Applications/.Latchkey-replaced.app
NEW=/Applications/.Latchkey-new.app

MNT=$(mktemp -d)
trap 'hdiutil detach -quiet "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; rm -rf "$NEW"' EXIT
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MNT" "$DMG"
rm -rf "$NEW"
ditto "$MNT/Latchkey.app" "$NEW"
codesign --verify --deep --strict "$NEW"

if pgrep -x Latchkey >/dev/null; then
  pkill -TERM -x Latchkey
  i=0
  while pgrep -x Latchkey >/dev/null && [ $i -lt 40 ]; do sleep 0.25; i=$((i + 1)); done
  pgrep -x Latchkey >/dev/null && pkill -KILL -x Latchkey && sleep 1
fi

rm -rf "$OLD"
[ -d "$DEST" ] && mv "$DEST" "$OLD"
if ! mv "$NEW" "$DEST"; then
  [ -d "$OLD" ] && mv "$OLD" "$DEST"
  echo "install: couldn't put the new app in place; the old one is back" >&2
  exit 1
fi
rm -rf "$OLD"

START=$(date "+%Y-%m-%d %H:%M:%S")
open "$DEST"
i=0
while [ $i -lt 30 ]; do
  line=$(/usr/bin/log show --start "$START" --predicate 'subsystem == "net.melisma.latchkey" AND category == "lifecycle"' \
    --style compact 2>/dev/null | grep "Started $VERSION" | tail -1 || true)
  if [ -n "$line" ]; then
    echo "install: Latchkey $VERSION installed and running (${line#*lifecycle] })"
    exit 0
  fi
  sleep 1
  i=$((i + 1))
done
echo "install: Latchkey $VERSION is installed but didn't report starting within 30 seconds" >&2
exit 1
