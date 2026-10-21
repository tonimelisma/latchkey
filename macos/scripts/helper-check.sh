#!/bin/sh
# After the helper is approved once in System Settings, checks keep-awake end to end on this
# Mac (FR-030, FR-035): SleepDisabled on while the app runs with keep-awake on, off after quit,
# off after a crash.
set -eu
APP=${APP:-/Applications/Latchkey.app}
sleepdisabled() { pmset -g | awk '$1=="SleepDisabled"{print $2; f=1} END{if(!f) print 0}'; }
wait_for() { i=0; while [ "$(sleepdisabled)" != "$1" ] && [ $i -lt 30 ]; do sleep 1; i=$((i+1)); done; [ "$(sleepdisabled)" = "$1" ]; }

launchctl print system/net.melisma.latchkey.helper >/dev/null 2>&1 || { echo "FAIL: helper not loaded (approve it in System Settings → General → Login Items)"; exit 1; }
echo "• helper is loaded"

open "$APP"
wait_for 1 || { echo "FAIL: SleepDisabled not set while Latchkey runs with keep-awake on"; exit 1; }
echo "• keep-awake on: SleepDisabled = 1"

osascript -e 'quit app "Latchkey"'
wait_for 0 || { echo "FAIL: sleep not restored after quitting (FR-035)"; exit 1; }
echo "• after quit: SleepDisabled = 0"

open "$APP"
wait_for 1 || { echo "FAIL: SleepDisabled not set after relaunch"; exit 1; }
pkill -9 -x Latchkey
wait_for 0 || { echo "FAIL: sleep not restored after the app crashed (FR-035)"; exit 1; }
echo "• after a crash: SleepDisabled = 0"

open "$APP"
echo PASS
