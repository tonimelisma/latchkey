#!/bin/sh
# Tests for the installer's checks of the running app after an install (spec 001 FR-622;
# macos/scripts/install-lib.sh). Nothing is installed; the inputs are log lines as the app writes
# them. Run: scripts/tests/install_checks_test.sh (or `make -C relay script-tests`).
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=macos/scripts/install-lib.sh
. "$root/macos/scripts/install-lib.sh"
fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
# check <name> <wanted exit code> <function and args...>
check() {
  name=$1 want=$2
  shift 2
  out=$("$@" 2>&1)
  code=$?
  if [ "$code" = "$want" ]; then ok "$name"; else bad "$name: exit $code, wanted $want: $out"; fi
}

# A window after an install: only when the app said setup is unfinished (2026-10-27 it opened
# over a finished setup).
check "no window, setup finished" 0 window_verdict 0 "Setup is finished"
check "a window though setup is finished" 1 window_verdict 1 "Setup is finished"
check "a window and no word from the app" 1 window_verdict 1 ""
check "a window for a real missing step" 0 window_verdict 1 "Opening setup: missing location"
check "no window, no line yet" 0 window_verdict 0 ""

on='Keep-awake on (wanted on); power adapter; lid open; thermal nominal; sleep disabled true; battery 80%'
failed='Keep-awake off_helper_unavailable (wanted on); power adapter; lid open; thermal nominal; sleep disabled false; battery 80%'
user_off='Keep-awake off_user (wanted off_user); battery; lid open; thermal nominal; sleep disabled false; battery 60%'
low='Keep-awake off_low_battery (wanted off_low_battery); battery; lid open; thermal nominal; sleep disabled false; battery 12%'

# Keep-awake as the app wants it (2026-10-25 to 27 it was silently off).
check "keep-awake on as wanted" 0 keepawake_verdict "$on"
check "keep-awake wanted but the helper didn't do it" 1 keepawake_verdict "$failed"
check "keep-awake off by the Owner" 0 keepawake_verdict "$user_off"
check "keep-awake off for a low battery" 0 keepawake_verdict "$low"
check "no keep-awake line" 1 keepawake_verdict ""

# The helper running is the one just installed, whenever keep-awake is wanted.
check "new helper started" 0 helper_verdict 0.8.23 "$on" "Helper 0.8.23 started; restoring sleep"
check "only an old helper's line" 1 helper_verdict 0.8.23 "$on" "Helper 0.8.22 started; restoring sleep"
check "no helper line while keep-awake is wanted" 1 helper_verdict 0.8.23 "$on" ""
check "keep-awake not wanted: helper not needed" 0 helper_verdict 0.8.23 "$user_off" ""

[ "$fails" = 0 ] && echo "all install check tests pass" || echo "$fails install check tests failed"
[ "$fails" = 0 ]
