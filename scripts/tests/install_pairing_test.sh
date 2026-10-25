#!/bin/sh
# Tests for the installer's check that an update didn't lose the pairing
# (macos/scripts/install-lib.sh). Nothing is installed, and the app's own Keychain items are
# never looked at: the one Keychain test uses a throwaway service name.
# Run: scripts/tests/install_pairing_test.sh (or `make -C relay script-tests`).
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=macos/scripts/install-lib.sh
. "$root/macos/scripts/install-lib.sh"
fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
# is <name> <got> <wanted>
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2', wanted '$3'"; fi; }

paired='Started 0.8.10, paired with <mask.hash: '"'"'abc=='"'"'>'
unpaired='Started 0.8.10, not paired (missing pairing record)'

# Was this Mac paired before the install? The running app's own start line decides; without one
# (the app wasn't running, or its line is gone from the log) the pairing record does.
is "the old app said paired" "$(paired_before "$paired" present)" yes
is "the old app said paired, whatever the record" "$(paired_before "$paired" absent)" yes
is "the old app said not paired" "$(paired_before "$unpaired" absent)" no
is "the old app said not paired though a record is there" \
  "$(paired_before 'Started 0.8.10, not paired (pairing record present but unreadable: Keychain error -50)' present)" no
is "no start line, a pairing record" "$(paired_before '' present)" yes
is "no start line, no pairing record" "$(paired_before '' absent)" no

# verdict <name> <wanted exit code> <args to install_verdict...>: runs it, keeps the output in $out.
verdict() {
  name=$1 want=$2
  shift 2
  out=$(install_verdict "$@" 2>&1)
  code=$?
  is "$name: exit code" "$code" "$want"
}
says() { if printf '%s' "$out" | grep -qF -- "$2"; then ok "$1"; else bad "$1: no '$2' in: $out"; fi; }
silent_on() { if printf '%s' "$out" | grep -qF -- "$2"; then bad "$1: '$2' in: $out"; else ok "$1"; fi; }

new_paired='Started 0.8.11, paired with <mask.hash: '"'"'abc=='"'"'>'
new_unpaired='Started 0.8.11, not paired (missing pairing record)'

verdict "paired before and after" 0 yes 0.8.10 0.8.11 "$new_paired" present ''
says "it reports the start line" "Latchkey 0.8.11 installed and running (Started 0.8.11, paired with"
silent_on "and raises no alarm" "PAIRING LOST"

verdict "not paired before or after" 0 no 0.8.10 0.8.11 "$new_unpaired" absent ''
says "it reports the start line" "not paired (missing pairing record)"
says "and that this is no change" "It wasn't paired before the install either."
silent_on "and raises no alarm" "PAIRING LOST"

verdict "not paired before, paired after" 0 no 0.8.10 0.8.11 "$new_paired" present ''

# The case of 2026-10-24: the old app was paired, the new one says it isn't.
verdict "paired before, not after, record still there" 1 yes 0.8.10 0.8.11 \
  'Started 0.8.11, not paired (pairing record present but unreadable: Keychain error -50)' present 'build/Latchkey-0.8.10.dmg'
says "it is loud" "PAIRING LOST"
says "it names the old version" "Latchkey 0.8.10 was paired"
says "it names the new version and what it said" "Latchkey 0.8.11 started not paired (pairing record present but unreadable: Keychain error -50)"
says "it says the record is still there" "The pairing record is still in the Keychain"
says "it says not to pair again" "Don't pair again yet"
says "it points at the previous disk image" "build/Latchkey-0.8.10.dmg"
silent_on "it doesn't claim success" "installed and running"

verdict "paired before, not after, record gone" 1 yes 0.8.10 0.8.11 "$new_unpaired" absent ''
says "it is loud" "PAIRING LOST"
says "it says the record is gone" "The pairing record is no longer in the Keychain"
says "it says not to pair again" "Don't pair again yet"
says "it says the previous disk image isn't there" "previous disk image is no longer in macos/build"

# The look at the Keychain: attributes only, tried on a throwaway item (never the app's own).
if command -v security >/dev/null 2>&1; then
  service="net.melisma.latchkey.tests.install.$$"
  is "no item: absent" "$(pairing_record "$service")" absent
  if security add-generic-password -s "$service" -a pairing -w throwaway >/dev/null 2>&1; then
    is "an item: present" "$(pairing_record "$service")" present
    security delete-generic-password -s "$service" -a pairing >/dev/null 2>&1
    is "deleted again: absent" "$(pairing_record "$service")" absent
  else
    ok "skipped: this keychain takes no test item"
  fi
fi

[ "$fails" = 0 ] && echo "all passed" || echo "$fails failed"
[ "$fails" = 0 ]
