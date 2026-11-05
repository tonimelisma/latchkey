#!/bin/sh
# Installs the newest build/Latchkey-<version>.dmg into /Applications and starts it, as the Owner
# would by dragging it there (Toni, 2026-10-23: every increment installs itself). Quits the
# running app cleanly first (SIGTERM: it says goodbye to the relay and restores sleep), swaps the
# app in place, removes the old copy, opens the new one, and checks it started. Permissions and the
# pairing carry over: same signature, same settings and Keychain. That is checked, not assumed:
# if this Mac was paired before and the new app starts "not paired", the install fails loudly
# (install-lib.sh; on 2026-10-24 it reported success after exactly that). Then it checks the app
# as the Owner meets it: no setup window over a finished setup, keep-awake as wanted, the new
# helper running (spec 001 FR-622), and the activity log agreeing with the relay's audit (FR-636).
set -eu
# One install at a time on this Mac, waiting up to 15 minutes for another to finish (2026-11-04:
# two sessions installed at once and one swapped the app out from under the other).
LOCK=$HOME/Library/Caches/net.melisma.latchkey.install.lock
if [ "${LATCHKEY_INSTALL_LOCKED:-}" != "$LOCK" ]; then
  LATCHKEY_INSTALL_LOCKED=$LOCK exec /usr/bin/lockf -t 900 "$LOCK" "$0" "$@"
fi
cd "$(dirname "$0")/.."
# Never replace newer work: the build must contain everything already on GitHub's main, so an
# install can't take back what another session shipped. Checked inside the lock, after a fetch.
git fetch -q origin main
if ! git merge-base --is-ancestor refs/remotes/origin/main HEAD; then
  echo "install: this checkout lacks commits already on origin/main (another session shipped);" >&2
  echo "install: rebase onto origin/main, retest, push to main, then install" >&2
  exit 1
fi
# shellcheck source=macos/scripts/install-lib.sh
. scripts/install-lib.sh
# The version is this commit's release tag, mac-<x.y.z> on GitHub, given or reused here (Toni,
# 2026-11-04: releases are tags on commits, so two sessions never ship the same number). The
# image is built inside the lock, for this number.
VERSION=$(../scripts/release-tag.sh mac-)
VERSION=$VERSION ./scripts/package.sh >/dev/null
DMG=build/Latchkey-$VERSION.dmg
[ -f "$DMG" ] || { echo "install: $DMG not found after building it" >&2; exit 1; }
echo "install: building and installing Latchkey $VERSION (tag mac-$VERSION)"
DEST=/Applications/Latchkey.app
OLD=/Applications/.Latchkey-replaced.app
NEW=/Applications/.Latchkey-new.app

MNT=$(mktemp -d)
trap 'hdiutil detach -quiet "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; rm -rf "$NEW"' EXIT
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MNT" "$DMG"
rm -rf "$NEW"
ditto "$MNT/Latchkey.app" "$NEW"
codesign --verify --deep --strict "$NEW"
# Never install code with the debugging entitlement (package.sh checks too; security scan 2026-10-24).
find "$NEW" -type f -perm -u+x | while read -r bin; do
  if codesign -d --entitlements - --xml "$bin" 2>/dev/null | grep -q 'com.apple.security.get-task-allow'; then
    echo "install: $bin is signed with com.apple.security.get-task-allow; not installed" >&2
    exit 1
  fi
done

PREDICATE='subsystem == "net.melisma.latchkey" AND category == "lifecycle"'
# start_line <from> [<to>]: the app's last "Started …" line in the log between the two times.
start_line() {
  if [ -n "${2:-}" ]; then set -- --start "$1" --end "$2"; else set -- --start "$1"; fi
  /usr/bin/log show "$@" --predicate "$PREDICATE" --style compact 2>/dev/null |
    grep "lifecycle\] Started " | tail -1 | sed 's/.*lifecycle\] //' || true
}

# Was this Mac paired before? The running app's start line says (written within moments of the
# time the process started); the pairing record's presence is the fallback. No secret is read.
OLD_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist" 2>/dev/null || echo "an earlier version")
OLD_LINE=""
if pid=$(pgrep -x Latchkey | head -1) && [ -n "$pid" ]; then
  if began=$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null) && [ -n "$began" ]; then
    from=$(LC_ALL=C date -j -v-5S -f "%a %b %d %T %Y" "$began" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || true)
    to=$(LC_ALL=C date -j -v+2M -f "%a %b %d %T %Y" "$began" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || true)
    if [ -n "$from" ] && [ -n "$to" ]; then OLD_LINE=$(start_line "$from" "$to"); fi
  fi
fi
PAIRED_BEFORE=$(paired_before "$OLD_LINE" "$(pairing_record)")
PREVIOUS_DMG=""
[ "$OLD_VERSION" != "$VERSION" ] && [ -f "build/Latchkey-$OLD_VERSION.dmg" ] && PREVIOUS_DMG="build/Latchkey-$OLD_VERSION.dmg"

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
started=""
while [ $i -lt 30 ]; do
  started=$(start_line "$START" | grep "Started $VERSION" || true)
  [ -n "$started" ] && break
  sleep 1
  i=$((i + 1))
done
if [ -z "$started" ]; then
  echo "install: Latchkey $VERSION is installed but didn't report starting within 30 seconds" >&2
  exit 1
fi
install_verdict "$PAIRED_BEFORE" "$OLD_VERSION" "$VERSION" "$started" "$(pairing_record)" "$PREVIOUS_DMG" || exit 1

# Then the app as the Owner would meet it (spec 001 FR-622): no setup window over a finished
# setup, keep-awake as the app wants it, and the helper just installed running. Each failed
# silently once (2026-10-25 to 27) while the install reported success.
# last_line <category> <text the line starts with>: the app's newest such line since START.
last_line() {
  /usr/bin/log show --start "$START" --predicate "subsystem == \"net.melisma.latchkey\" AND category == \"$1\"" \
    --style compact 2>/dev/null | sed -n "s/.*:$1\] //p" | grep "^$2" | tail -1 || true
}
# Keep-awake: the helper may need launchd's 10-second wait and the app's retries every 12 s.
i=0
while [ $i -lt 45 ]; do
  awake=$(last_line keepawake "Keep-awake ")
  state=$(keepawake_state "$awake")
  [ -n "$state" ] && [ "${state% *}" = "${state#* }" ] && break
  sleep 2
  i=$((i + 1))
done
# The setup decision comes within 5 seconds of start.
i=0
while [ $i -lt 10 ]; do
  setup=$(last_line permissions "Opening setup\|Setup is finished")
  [ -n "$setup" ] && break
  sleep 1
  i=$((i + 1))
done
windows=$(swift scripts/count-windows.swift 2>/dev/null || echo "?")
helper=$(last_line helper "Helper ")
# The comparison with the relay's audit runs right after the app connects (spec 001 FR-634); a
# relay page may take up to 15 s, and a relay that closes on the request is seen on the reconnect.
audit=""
case "$started" in
  *"not paired"*) echo "install: not paired, so no audit check against a relay" ;;
  *)
    i=0
    while [ $i -lt 60 ]; do
      audit=$(last_line audit "Audit check")
      [ -n "$audit" ] && break
      sleep 2
      i=$((i + 1))
    done
    ;;
esac
failed=0
keepawake_verdict "$awake" || failed=1
helper_verdict "$VERSION" "$awake" "$helper" || failed=1
window_verdict "$windows" "$setup" || failed=1
case "$started" in *"not paired"*) ;; *) audit_verdict "$audit" || failed=1 ;; esac
exit $failed
