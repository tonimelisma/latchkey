#!/bin/sh
# Sets up the Mac's updater (macos/scripts/auto-update.sh) as a per-user launchd agent,
# net.melisma.latchkey.updater: every 15 minutes, at login, and when a file appears in its
# requests folder. `make -C macos install` (install.sh) runs this after every install, so the
# updater's own script is always the installed release's; run it by hand once to start updating
# a Mac that has none yet:   macos/scripts/updater-setup.sh
#   macos/scripts/updater-setup.sh remove    stops the agent and removes it (the clone stays in
#                                            the cache folder until macOS clears it)
# The build signs with the main checkout's gitignored Local.xcconfig (and reads its .env), so the
# agent is told where that checkout is: this checkout's main one, or LATCHKEY_LOCAL_FILES_FROM.
# Run by the updater itself (LATCHKEY_UPDATER=1) it only refreshes the files: reloading the
# agent would stop the run in progress; a changed agent file is used from the next login.
# Tested by scripts/tests/auto_update_test.sh (LAUNCHCTL replaces launchctl there).
set -eu
LABEL=net.melisma.latchkey.updater
UPDATER_HOME=${UPDATER_HOME:-$HOME/Library/Caches/net.melisma.latchkey.updater}
AGENTS=${LATCHKEY_LAUNCH_AGENTS:-$HOME/Library/LaunchAgents}
PLIST=$AGENTS/$LABEL.plist
LOG=${LATCHKEY_UPDATER_LOG:-$HOME/Library/Logs/Latchkey Updater.log}
LAUNCHCTL=${LAUNCHCTL:-launchctl}
here=$(cd "$(dirname "$0")" && pwd)
domain=gui/$(id -u)

if [ "${1:-}" = remove ]; then
  $LAUNCHCTL bootout "$domain/$LABEL" 2>/dev/null || true
  rm -f "$PLIST" "$UPDATER_HOME/auto-update.sh"
  echo "updater: removed"
  exit 0
fi

main=${LATCHKEY_LOCAL_FILES_FROM:-$(dirname "$(git -C "$here" rev-parse --path-format=absolute --git-common-dir)")}
if [ ! -f "$main/macos/Config/Local.xcconfig" ]; then
  echo "updater: $main has no macos/Config/Local.xcconfig (the signing team); builds would be signed as another app. Not set up." >&2
  exit 1
fi

mkdir -p "$UPDATER_HOME/requests" "$AGENTS" "$(dirname "$LOG")"
# Replaced by a rename: a run in progress keeps reading the old file.
cp "$here/auto-update.sh" "$UPDATER_HOME/auto-update.sh.new"
chmod 755 "$UPDATER_HOME/auto-update.sh.new"
mv -f "$UPDATER_HOME/auto-update.sh.new" "$UPDATER_HOME/auto-update.sh"

xml() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }
cat >"$PLIST.new" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/sh</string>
		<string>$(xml "$UPDATER_HOME/auto-update.sh")</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
		<key>UPDATER_HOME</key>
		<string>$(xml "$UPDATER_HOME")</string>
		<key>LATCHKEY_LOCAL_FILES_FROM</key>
		<string>$(xml "$main")</string>
		<key>LATCHKEY_UPDATER_LOG</key>
		<string>$(xml "$LOG")</string>
	</dict>
	<key>StartInterval</key>
	<integer>900</integer>
	<key>RunAtLoad</key>
	<true/>
	<key>QueueDirectories</key>
	<array>
		<string>$(xml "$UPDATER_HOME/requests")</string>
	</array>
	<key>ProcessType</key>
	<string>Standard</string>
	<key>StandardOutPath</key>
	<string>$(xml "$LOG")</string>
	<key>StandardErrorPath</key>
	<string>$(xml "$LOG")</string>
</dict>
</plist>
EOF
changed=1
if [ -f "$PLIST" ] && cmp -s "$PLIST" "$PLIST.new"; then changed=''; fi
mv -f "$PLIST.new" "$PLIST"
if [ "${LATCHKEY_UPDATER:-}" = 1 ]; then
  [ -z "$changed" ] || echo "updater: its agent file changed; launchd uses it from the next login"
  exit 0
fi
if $LAUNCHCTL print "$domain/$LABEL" >/dev/null 2>&1; then
  [ -n "$changed" ] || { echo "updater: up to date"; exit 0; }
  # Reloading stops a run in progress, which may be in the middle of an install.
  if [ -x /usr/bin/lockf ] && ! /usr/bin/lockf -t 0 "$UPDATER_HOME/lock" true 2>/dev/null; then
    echo "updater: a run is in progress; its new agent file is used from the next login"
    exit 0
  fi
  $LAUNCHCTL bootout "$domain/$LABEL" 2>/dev/null || true
fi
$LAUNCHCTL bootstrap "$domain" "$PLIST"
echo "updater: running every 15 minutes (log: $LOG)"
