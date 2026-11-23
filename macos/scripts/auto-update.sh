#!/bin/sh
# The Mac's updater: builds and installs the newest Mac release, the way the relay's hosts and the
# Linux servers update themselves. A per-user launchd agent (net.melisma.latchkey.updater, set up by
# macos/scripts/updater-setup.sh, which `make -C macos install` runs) starts it every 15 minutes,
# at login, and whenever a request file appears in its requests folder. launchd is its parent, so
# quitting Latchkey (which every install does) never stops it, and Claude can start it through
# Latchkey's Shell by writing a request file (launchctl isn't possible from Shell).
#
# A release is a tag mac-<x.y.z> that CI made on a commit on main (.github/workflows/mac-tag.yml,
# in the environment "release", where the owner can require an approval): only such commits are
# built. When the newest tag isn't the installed version, the tagged commit is checked out in the
# updater's own clone and installed with the usual `make -C macos install` (install.sh: signed with
# the main checkout's Local.xcconfig and the Keychain's certificate, waits until Latchkey has been
# idle for 10 minutes, quits and replaces the app, checks it, publishes the disk image). Busy for
# 30 minutes (install.sh's exit 3): tried again next time. A failed install is tried again after
# 6 hours, or at once on a request.
#
# Requests (files in $UPDATER_HOME/requests; any content):
#   now           check and install now (still waiting for idle)
#   install-now   the same with LATCHKEY_INSTALL_NOW=1: no idle wait (only when the owner says so)
# Everything it does goes to $LOG; `auto-update.sh status` prints the state and the log's end.
# Settings (the agent sets them; tests override them):
#   UPDATER_HOME   default ~/Library/Caches/net.melisma.latchkey.updater (clone, requests, state)
#   LATCHKEY_LOCAL_FILES_FROM   the main checkout whose .env, CLAUDE.local.md, Local.xcconfig the
#                  build links (scripts/link-local-files.sh)
#   LATCHKEY_UPDATER_REPO, LATCHKEY_UPDATER_APP, LATCHKEY_UPDATER_LOG, LATCHKEY_UPDATER_INSTALL
# Tested by scripts/tests/auto_update_test.sh.
set -u
UPDATER_HOME=${UPDATER_HOME:-$HOME/Library/Caches/net.melisma.latchkey.updater}
REPO=${LATCHKEY_UPDATER_REPO:-https://github.com/tonimelisma/latchkey.git}
APP=${LATCHKEY_UPDATER_APP:-/Applications/Latchkey.app}
LOG=${LATCHKEY_UPDATER_LOG:-$HOME/Library/Logs/Latchkey Updater.log}
CHECKOUT=$UPDATER_HOME/latchkey
REQUESTS=$UPDATER_HOME/requests
RETRY_FAILED=21600

# installed_version: the installed app's version, or nothing.
installed_version() {
  plist=$APP/Contents/Info.plist
  [ -f "$plist" ] || return 0
  if [ -x /usr/libexec/PlistBuddy ]; then
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null
  else
    sed -n '/<key>CFBundleShortVersionString<\/key>/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' "$plist"
  fi
}

if [ "${1:-}" = status ]; then
  echo "installed: $(installed_version)"
  echo "newest release: $(git -C "$CHECKOUT" tag --list 'mac-[0-9]*' --sort=-v:refname 2>/dev/null | head -1)"
  [ -f "$UPDATER_HOME/failed" ] && echo "last failure (version, time): $(cat "$UPDATER_HOME/failed")"
  [ -n "$(ls -A "$REQUESTS" 2>/dev/null)" ] && echo "requests waiting: $(ls -A "$REQUESTS" | tr '\n' ' ')"
  tail -20 "$LOG" 2>/dev/null
  exit 0
fi

mkdir -p "$UPDATER_HOME" "$REQUESTS" "$(dirname "$LOG")"
# One run at a time; a run that finds another running leaves the requests for it.
if [ "${LATCHKEY_UPDATER_LOCKED:-}" != 1 ]; then
  if [ -x /usr/bin/lockf ]; then
    LATCHKEY_UPDATER_LOCKED=1 exec /usr/bin/lockf -t 0 "$UPDATER_HOME/lock" /bin/sh "$0" "$@" 2>/dev/null
  elif command -v flock >/dev/null 2>&1; then
    LATCHKEY_UPDATER_LOCKED=1 exec flock -n "$UPDATER_HOME/lock" /bin/sh "$0" "$@"
  fi
fi
# The log stays small: one older copy is kept.
if [ -f "$LOG" ] && [ "$(wc -c <"$LOG")" -gt 1000000 ]; then mv -f "$LOG" "$LOG.1"; fi
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG"; }

requested='' now_flag=''
for f in "$REQUESTS"/* "$REQUESTS"/.[!.]*; do
  [ -e "$f" ] || continue
  case $(basename "$f") in install-now) now_flag=1 ;; esac
  requested=1
  rm -f "$f"
done
[ -z "$requested" ] || log "request: check now${now_flag:+, without waiting for idle}"

if [ ! -d "$CHECKOUT/.git" ]; then
  rm -rf "$CHECKOUT"
  if ! git clone -q "$REPO" "$CHECKOUT" 2>>"$LOG"; then
    log "couldn't clone $REPO; trying again next time"
    exit 0
  fi
fi
if ! git -C "$CHECKOUT" fetch -q --force --prune origin '+refs/heads/main:refs/remotes/origin/main' '+refs/tags/mac-*:refs/tags/mac-*' 2>>"$LOG"; then
  [ -z "$requested" ] || log "couldn't reach GitHub; trying again next time"
  exit 0
fi
tag=$(git -C "$CHECKOUT" tag --list 'mac-[0-9]*' --sort=-v:refname | head -1)
[ -n "$tag" ] || { log "no Mac release tag on GitHub"; exit 0; }
if ! git -C "$CHECKOUT" merge-base --is-ancestor "$tag^{commit}" refs/remotes/origin/main; then
  log "$tag isn't on main; not installing it"
  exit 0
fi
version=${tag#mac-}
installed=$(installed_version)
if [ "$installed" = "$version" ]; then
  rm -f "$UPDATER_HOME/failed"
  [ -z "$requested" ] || log "Latchkey $version is installed; nothing to do"
  exit 0
fi
# A newer version than any release (a build of a local session's) is left alone.
if [ -n "$installed" ] && [ "$(printf '%s\n%s\n' "$installed" "$version" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" = "$installed" ]; then
  [ -z "$requested" ] || log "installed $installed is newer than the newest release $version; nothing to do"
  exit 0
fi
if [ -z "$requested" ] && [ -f "$UPDATER_HOME/failed" ]; then
  read -r failed_version failed_at <"$UPDATER_HOME/failed" || true
  case ${failed_at:-} in '' | *[!0-9]*) failed_at=0 ;; esac
  if [ "${failed_version:-}" = "$version" ] && [ $(($(date +%s) - failed_at)) -lt $RETRY_FAILED ]; then exit 0; fi
fi

log "installing Latchkey $version (installed: ${installed:-none})"
if ! git -C "$CHECKOUT" checkout -q --detach --force "$tag" 2>>"$LOG"; then
  log "couldn't check out $tag"
  exit 0
fi
rc=0
if [ -n "${LATCHKEY_UPDATER_INSTALL:-}" ]; then
  (cd "$CHECKOUT" && LATCHKEY_UPDATER=1 LATCHKEY_INSTALL_NOW=$now_flag sh -c "$LATCHKEY_UPDATER_INSTALL") >>"$LOG" 2>&1 || rc=$?
else
  (cd "$CHECKOUT" && LATCHKEY_UPDATER=1 LATCHKEY_INSTALL_NOW=$now_flag make -C macos install) >>"$LOG" 2>&1 || rc=$?
fi
case $rc in
  0)
    log "installed Latchkey $version"
    rm -f "$UPDATER_HOME/failed"
    ;;
  3) log "Latchkey was busy; trying $version again in 15 minutes" ;;
  *)
    log "installing $version failed (exit $rc); trying again in 6 hours or on a request"
    printf '%s %s\n' "$version" "$(date +%s)" >"$UPDATER_HOME/failed"
    ;;
esac
exit 0
