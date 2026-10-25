#!/bin/sh
# Fails if one of this deployment's private values is in the repository: in a tracked file, or in
# any commit (contents or message) reachable from any branch, tag or other ref. Secret scanners
# can't know these values; this script reads them from the gitignored files that hold them:
#   .env                          DEPLOY_HOST, DEPLOY_DNS_ZONE, DEPLOY_VM, DEPLOY_PROJECT
#   macos/Config/Local.xcconfig   DEVELOPMENT_TEAM, LATCHKEY_DEFAULT_RELAY_HOST
# (taken from the main checkout when a worktree has no copy). Run it inside the repository to
# check. It prints where a value was found and which setting it is, never the value.
# Matching is literal and ignores case. Values under 6 characters and the cloud zone (DEPLOY_ZONE,
# a generic region name) are not searched: they would match ordinary text. The reversed DNS zone
# in the app's bundle ID is not a match (only the forward form is searched).
# Exit: 0 clean (or no private files to compare with), 1 found, 2 could not check.
# Used by `make secrets` in relay/ and before every `git push` from Claude Code (scripts/hooks.sh).
# Tested by scripts/tests/private_values_test.sh.
set -u
top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "private-values-check: not inside a git repository" >&2; exit 2; }
common=$(git -C "$top" rev-parse --path-format=absolute --git-common-dir) || exit 2
main=$(dirname "$common")

# private_file PATH: the worktree's copy, else the main checkout's; empty when neither exists.
private_file() {
  for dir in "$top" "$main"; do
    if [ -f "$dir/$1" ]; then
      printf '%s\n' "$dir/$1"
      return
    fi
  done
}

# env_value NAME FILE: NAME=value (optionally exported or quoted) from a shell settings file.
env_value() {
  sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1=//p" "$2" | tail -1 |
    sed "s/[[:space:]]*\$//; s/^[\"']//; s/[\"']\$//"
}

# xcconfig_value NAME FILE: NAME = value from an Xcode settings file.
xcconfig_value() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$2" | tail -1 |
    sed 's|[[:space:]]*//.*$||; s/[[:space:]]*$//'
}

found=0
seen='
'
# check NAME VALUE
check() {
  [ "${#2}" -ge 6 ] || return 0
  case $seen in *"
$2
"*) return 0 ;; esac
  seen="$seen$2
"
  hits=$(git -C "$top" grep -n -i -F -e "$2" -- . 2>/dev/null | cut -d: -f1,2)
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" | sed "s/^/private value ($1) in a tracked file: /"
    found=1
  fi
  if ! commits=$(git -C "$top" log --all -i -S"$2" --format=%h 2>/dev/null); then
    echo "private-values-check: could not search the history" >&2
    exit 2
  fi
  for c in $commits; do
    echo "private value ($1) in the history: commit $c adds or removes it"
    found=1
  done
  for c in $(git -C "$top" log --all -i -F --grep="$2" --format=%h 2>/dev/null); do
    echo "private value ($1) in the history: message of commit $c"
    found=1
  done
}

env_file=$(private_file .env)
xc_file=$(private_file macos/Config/Local.xcconfig)
if [ -z "$env_file" ] && [ -z "$xc_file" ]; then
  echo "private-values-check: no .env or macos/Config/Local.xcconfig here; nothing to compare with"
  exit 0
fi
if [ -n "$env_file" ]; then
  for name in DEPLOY_HOST DEPLOY_DNS_ZONE DEPLOY_VM DEPLOY_PROJECT; do
    check "$name" "$(env_value "$name" "$env_file")"
  done
fi
if [ -n "$xc_file" ]; then
  for name in DEVELOPMENT_TEAM LATCHKEY_DEFAULT_RELAY_HOST; do
    check "$name" "$(xcconfig_value "$name" "$xc_file")"
  done
fi
if [ "$found" = 1 ]; then
  echo "FAIL: private values of this deployment are in the repository (CLAUDE.md: they live only in .env, macos/Config/Local.xcconfig and CLAUDE.local.md). Remove them before pushing."
  exit 1
fi
exit 0
