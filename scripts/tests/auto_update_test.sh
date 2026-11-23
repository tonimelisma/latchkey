#!/bin/sh
# Tests for the Mac's updater (macos/scripts/auto-update.sh) and its launchd agent
# (macos/scripts/updater-setup.sh) in temporary folders: a stand-in "origin" with release tags, a
# stand-in installed app, and a stand-in install command instead of `make -C macos install`;
# launchctl is replaced too. Nothing is built or installed. Runs on Linux and macOS.
# Run: scripts/tests/auto_update_test.sh (or `make -C relay script-tests`).
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
work=$(cd "$work" && pwd -P)
trap 'rm -rf "$work"' EXIT
fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (wanted '$3', got '$2')"; fi; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

# --- origin: main with two Mac releases ---
git init -q --bare -b main "$work/origin.git" 2>/dev/null || { git init -q --bare "$work/origin.git"; git -C "$work/origin.git" symbolic-ref HEAD refs/heads/main; }
git clone -q "$work/origin.git" "$work/dev" 2>/dev/null
git -C "$work/dev" checkout -q -b main 2>/dev/null || true
commit() { echo "$1" >>"$work/dev/f"; git -C "$work/dev" add f; git -C "$work/dev" commit -q -m "$1"; git -C "$work/dev" push -q origin HEAD:main 2>/dev/null; }
release() { git -C "$work/dev" tag "mac-$1"; git -C "$work/dev" push -q origin "refs/tags/mac-$1" 2>/dev/null; }
commit one
release 0.8.9
commit two
release 0.8.10
commit three # not a release

app() { # <version>: the installed app says it is this version
  mkdir -p "$work/Latchkey.app/Contents"
  cat >"$work/Latchkey.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
	<key>CFBundleShortVersionString</key>
	<string>$1</string>
</dict></plist>
EOF
}
app 0.8.9
# The stand-in install: records the commit, the version it was asked to install and its setting,
# answers with the exit code in $work/rc, and on success "installs" the commit's tag.
cat >"$work/install" <<'EOF'
#!/bin/sh
tag=$(git describe --tags --exact-match HEAD)
echo "$tag now=${LATCHKEY_INSTALL_NOW:-} updater=${LATCHKEY_UPDATER:-}" >>"$WORK/installs"
rc=$(cat "$WORK/rc")
if [ "$rc" = 0 ]; then
  sed -i.bak "s|<string>.*</string>|<string>${tag#mac-}</string>|" "$WORK/Latchkey.app/Contents/Info.plist"
fi
exit "$rc"
EOF
chmod +x "$work/install"
echo 0 >"$work/rc"
export WORK=$work
H=$work/home
run() {
  UPDATER_HOME=$H LATCHKEY_UPDATER_REPO=$work/origin.git LATCHKEY_UPDATER_APP=$work/Latchkey.app \
    LATCHKEY_UPDATER_LOG=$work/log LATCHKEY_UPDATER_INSTALL="$work/install" \
    sh "$root/macos/scripts/auto-update.sh" "$@"
}
installs() { [ -f "$work/installs" ] && wc -l <"$work/installs" | tr -d ' ' || echo 0; }

# --- a newer release is installed, the tagged commit and nothing else ---
run
is "the newest release is installed" "$(sed -n 1p "$work/installs" | cut -d' ' -f1)" "mac-0.8.10"
grep -q 'updater=1' "$work/installs" && ok "the install knows the updater runs it" || bad "the install knows the updater runs it"
grep -q 'now= ' "$work/installs" && ok "it waits for idle (no LATCHKEY_INSTALL_NOW)" || bad "it waits for idle (no LATCHKEY_INSTALL_NOW)"
is "from the tagged commit, not main's newer one" "$(git -C "$H/latchkey" rev-parse HEAD)" "$(git -C "$work/dev" rev-parse mac-0.8.10)"
grep -q "installed Latchkey 0.8.10" "$work/log" && ok "the log says so" || bad "the log says so"

# --- up to date: nothing ---
run
is "up to date: nothing is installed" "$(installs)" 1

# --- busy (install.sh's exit 3): tried again next time ---
commit four
release 0.8.11
echo 3 >"$work/rc"
run
grep -q "busy" "$work/log" && ok "busy is logged" || bad "busy is logged"
run
is "busy: tried again on the next run" "$(installs)" 3

# --- failed: not again for 6 hours, unless asked ---
echo 1 >"$work/rc"
run
is "a failed install is tried" "$(installs)" 4
run
is "and not again right away" "$(installs)" 4
touch "$H/requests/now"
run
is "a request tries it again at once" "$(installs)" 5
[ -z "$(ls -A "$H/requests")" ] && ok "the request is used up" || bad "the request is used up"

# --- install-now: no idle wait ---
echo 0 >"$work/rc"
touch "$H/requests/install-now"
run
grep -q 'mac-0.8.11 now=1' "$work/installs" && ok "install-now skips the idle wait" || bad "install-now skips the idle wait"
[ ! -f "$H/failed" ] && ok "a success clears the failure" || bad "a success clears the failure"

# --- a newer version installed by hand (a local session's build) is left alone ---
app 0.9.0
run
is "a newer installed version stays" "$(installs)" 6

# --- a tag that isn't on main is never installed ---
app 0.8.11
git -C "$work/dev" checkout -q -b side
echo side >>"$work/dev/f"; git -C "$work/dev" commit -q -am side
release 0.8.12
git -C "$work/dev" checkout -q main
run
is "a release tag off main isn't installed" "$(installs)" 6
grep -q "mac-0.8.12 isn't on main" "$work/log" && ok "and the log says why" || bad "and the log says why"

# --- status ---
run status >"$work/status"
grep -q "installed: 0.8.11" "$work/status" && ok "status shows the installed version" || bad "status shows the installed version"

# --- one run at a time ---
if command -v flock >/dev/null 2>&1; then
  touch "$H/requests/now"
  flock "$H/lock" env UPDATER_HOME="$H" LATCHKEY_UPDATER_REPO="$work/origin.git" LATCHKEY_UPDATER_APP="$work/Latchkey.app" \
    LATCHKEY_UPDATER_LOG="$work/log" LATCHKEY_UPDATER_INSTALL="$work/install" sh "$root/macos/scripts/auto-update.sh"
  [ -f "$H/requests/now" ] && ok "a run while another holds the lock leaves the request for it" || bad "a run while another holds the lock leaves the request for it"
  rm -f "$H/requests/now"
fi

# --- the launchd agent ---
cat >"$work/launchctl" <<'EOF'
#!/bin/sh
echo "launchctl $*" >>"$WORK/launchctl.log"
case $1 in print) [ -f "$WORK/loaded" ] ;; bootstrap) touch "$WORK/loaded" ;; bootout) rm -f "$WORK/loaded" ;; esac
EOF
chmod +x "$work/launchctl"
mkdir -p "$work/main/macos/Config"
setup() {
  UPDATER_HOME=$H LATCHKEY_LAUNCH_AGENTS=$work/agents LATCHKEY_UPDATER_LOG=$work/log LAUNCHCTL=$work/launchctl \
    LATCHKEY_LOCAL_FILES_FROM=$work/main sh "$root/macos/scripts/updater-setup.sh" "$@" >"$work/setup.out" 2>&1
}
plist=$work/agents/net.melisma.latchkey.updater.plist
setup && bad "no signing settings: not set up" || ok "no signing settings: not set up"
[ ! -f "$plist" ] && ok "and no agent written" || bad "and no agent written"
echo "DEVELOPMENT_TEAM = TEST" >"$work/main/macos/Config/Local.xcconfig"
setup && ok "set up" || bad "set up: $(cat "$work/setup.out")"
grep -q "<string>$H/auto-update.sh</string>" "$plist" && ok "the agent runs the updater's own copy of the script" || bad "the agent runs the updater's own copy of the script"
cmp -s "$H/auto-update.sh" "$root/macos/scripts/auto-update.sh" && ok "which is this checkout's" || bad "which is this checkout's"
grep -q "<integer>900</integer>" "$plist" && ok "every 15 minutes" || bad "every 15 minutes"
grep -A2 "QueueDirectories" "$plist" | grep -q "<string>$H/requests</string>" && ok "and when a request appears" || bad "and when a request appears"
grep -A1 "LATCHKEY_LOCAL_FILES_FROM" "$plist" | grep -q "<string>$work/main</string>" && ok "with the main checkout's signing files" || bad "with the main checkout's signing files"
grep -q "bootstrap gui/" "$work/launchctl.log" && ok "loaded into the user's session" || bad "loaded into the user's session"
if command -v plutil >/dev/null 2>&1; then plutil -lint -s "$plist" && ok "a valid property list" || bad "a valid property list"; fi
: >"$work/launchctl.log"
setup
[ -s "$work/launchctl.log" ] && ! grep -q "bootout\|bootstrap" "$work/launchctl.log" && ok "unchanged: not reloaded" || bad "unchanged: not reloaded"
: >"$work/launchctl.log"
rm -f "$H/auto-update.sh"
UPDATER_HOME=$H LATCHKEY_LAUNCH_AGENTS=$work/agents LATCHKEY_UPDATER_LOG=$work/log LAUNCHCTL=$work/launchctl \
  LATCHKEY_LOCAL_FILES_FROM=$work/other LATCHKEY_UPDATER=1 sh "$root/macos/scripts/updater-setup.sh" >/dev/null 2>&1
mkdir -p "$work/other/macos/Config" && cp "$work/main/macos/Config/Local.xcconfig" "$work/other/macos/Config/"
UPDATER_HOME=$H LATCHKEY_LAUNCH_AGENTS=$work/agents LATCHKEY_UPDATER_LOG=$work/log LAUNCHCTL=$work/launchctl \
  LATCHKEY_LOCAL_FILES_FROM=$work/other LATCHKEY_UPDATER=1 sh "$root/macos/scripts/updater-setup.sh" >/dev/null 2>&1
[ -f "$H/auto-update.sh" ] && ok "run by the updater, the script is refreshed" || bad "run by the updater, the script is refreshed"
[ ! -s "$work/launchctl.log" ] && ok "but the agent isn't reloaded under the running updater" || bad "but the agent isn't reloaded under the running updater"
setup remove
[ ! -f "$plist" ] && grep -q "bootout" "$work/launchctl.log" && ok "remove stops and deletes the agent" || bad "remove stops and deletes the agent"

[ "$fails" -eq 0 ] && echo "auto_update_test: all passed" || { echo "auto_update_test: $fails failed"; exit 1; }
