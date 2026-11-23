#!/bin/sh
# Fails if a working relay's address or an Apple signing team is written in the repository (Toni,
# 2026-11-23: no working relay's host name ever goes into the repository). Needs no private
# values: wherever a relay's address is written, it must be a placeholder name, and the signing
# team setting must be empty. Checked: tracked files, and the added lines and messages of commits
# not yet on any remote (what a push would publish).
# Where a relay's address is written:
#   PUBLIC_URL=https://<host>, a connector URL https://<host>/mcp, a pairing link's relay=<url>,
#   LATCHKEY_DEFAULT_RELAY_HOST = <host>
# Placeholders: example.com, .net, .org and their subdomains, any name under .example, .test,
# .invalid or .localhost, localhost, loopback addresses, sslip.io names of documentation addresses
# (192.0.2.x, 198.51.100.x, 203.0.113.x), and variables or templates ($HOST, {{HOST}}, <name>).
# Signing team: DEVELOPMENT_TEAM = <ten letters and digits> fails unless it is the placeholder
# ABCDE12345; the real team lives only in the gitignored macos/Config/Local.xcconfig.
# It prints where it found something and what kind, never the value.
# Exit: 0 clean, 1 found, 2 could not check. Used by `make secrets` in relay/ and before every
# `git push` from Claude Code (scripts/hooks.sh). Tested by scripts/tests/private_values_test.sh.
set -u
top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "private-values-check: not inside a git repository" >&2; exit 2; }

# What to look for (extended regular expressions; case is ignored for the addresses).
q="'" # a single quote, for the patterns below
url_end="[^]/?#\"$q\`<>()[:space:],;|\\]"
addr_re="PUBLIC_URL[\"$q ]*[=:][\"$q ]*https?://$url_end+|https?://$url_end+/mcp([^a-z0-9_./-]|\$)|relay=https?(%3a|:)(%2f|/)(%2f|/)[^&\"$q\`<>()[:space:]]+|LATCHKEY_DEFAULT_RELAY_HOST[\"$q ]*[=:][\"$q ]*[^\"${q}[:space:]/]*[.][^\"${q}[:space:]/]+"
team_re="DEVELOPMENT_TEAM[\"$q ]*[=:][\"$q ]*[A-Z0-9]{10}([^A-Za-z0-9]|\$)"

# placeholder HOST: succeeds when HOST can't be anyone's working relay.
placeholder() {
  h=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  h=${h##*@}
  case $h in
    \[*) h=${h%%]*}] ;;
    *) h=${h%%:*} ;;
  esac
  h=${h%.}
  case $h in
    '' | '$'* | '{'* | '<'* | '('* | '%'* | \\* | '…'* | '...'*) return 0 ;;
    localhost | *.localhost | 127.* | '[::1]' | 0.0.0.0) return 0 ;;
    example.com | *.example.com | example.net | *.example.net | example.org | *.example.org) return 0 ;;
    example | *.example | test | *.test | invalid | *.invalid) return 0 ;;
    192-0-2-*.sslip.io | 198-51-100-*.sslip.io | 203-0-113-*.sslip.io) return 0 ;;
  esac
  return 1
}

# host_of MATCH: the host name a match names.
host_of() {
  case $1 in
    [Ll][Aa][Tt][Cc][Hh][Kk][Ee][Yy]_*) printf '%s' "$1" | sed "s/^[^=:]*[=:][\" $q]*//" ;;
    *) printf '%s' "$1" | sed 's/%3[Aa]/:/g; s/%2[Ff]/\//g; s|^.*://||; s|[/?#].*$||' ;;
  esac
}

found=0
tab=$(printf '\t')
# scan_addresses, scan_teams: read "<place><tab><match>" lines and report each match that names
# a real host or team.
scan_addresses() {
  while IFS="$tab" read -r place match; do
    placeholder "$(host_of "$match")" && continue
    echo "a relay's address in $place: use a placeholder such as relay.example.com"
    found=1
  done
}
scan_teams() {
  while IFS="$tab" read -r place match; do
    value=$(printf '%s' "$match" | sed "s/^[^=:]*[=:][\" $q]*//" | cut -c1-10)
    [ "$value" = ABCDE12345 ] && continue
    echo "a signing team in $place: leave DEVELOPMENT_TEAM empty (it lives in macos/Config/Local.xcconfig)"
    found=1
  done
}

tmp=$(mktemp) || exit 2
trap 'rm -f "$tmp" "$tmp.c"' EXIT
# files PATTERN [-i]: tracked files' matches as "<file>:<line><tab><match>" in $tmp.
files() { # shellcheck disable=SC2086 # $2 is an optional flag
  git -C "$top" grep -n -I -o -E ${2:-} -e "$1" -- . >"$tmp.c" 2>/dev/null
  [ $? -le 1 ] || { echo "private-values-check: could not search the files" >&2; exit 2; }
  sed "s/^\([^:]*:[0-9]*\):/\1$tab/" "$tmp.c" >"$tmp"
}
files "$addr_re" -i
scan_addresses <"$tmp"
files "$team_re"
scan_teams <"$tmp"

# Commits a push would publish: their messages and added lines.
if ! commits=$(git -C "$top" rev-list --all --not --remotes 2>/dev/null); then
  echo "private-values-check: could not list the commits" >&2
  exit 2
fi
for c in $commits; do
  short=$(git -C "$top" rev-parse --short "$c")
  git -C "$top" show --format=%B "$c" | grep -v '^-' >"$tmp.c"
  grep -n -o -i -E -e "$addr_re" "$tmp.c" | sed "s/^\([0-9]*\):/commit $short, line \1$tab/" >"$tmp"
  scan_addresses <"$tmp"
  grep -n -o -E -e "$team_re" "$tmp.c" | sed "s/^\([0-9]*\):/commit $short, line \1$tab/" >"$tmp"
  scan_teams <"$tmp"
done

if [ "$found" = 1 ]; then
  echo "FAIL: a working relay's address or a signing team is written in the repository; only placeholders may be."
  exit 1
fi
exit 0
