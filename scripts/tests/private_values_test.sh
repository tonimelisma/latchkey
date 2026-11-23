#!/bin/sh
# Tests for scripts/private-values-check.sh in a temporary repository. The made-up real-looking
# host and team are built from pieces, so this file itself holds only placeholders.
# Run: scripts/tests/private_values_test.sh (or `make -C relay script-tests`).
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
check="$root/scripts/private-values-check.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [ -f "$work/out" ] && sed 's/^/     /' "$work/out"; }
run() { (cd "$repo" && CLAUDE_CODE_REMOTE=true "$check") >"$work/out" 2>&1; code=$?; }
is() { if [ "$code" = "$1" ]; then ok "$2"; else bad "$2 (exit $code, wanted $1)"; fi; }
has() { if grep -q -- "$1" "$work/out"; then ok "$2"; else bad "$2"; fi; }
hasnt() { if grep -qi -- "$1" "$work/out"; then bad "$2"; else ok "$2"; fi; }
commit() { git -C "$repo" -c user.name=t -c user.email=t@example.com commit -q "$@"; }
host="latch.private""zone.net"
team="ZQ9X""8Y7W6V"
upper="LATCH.Private""Zone.net"

repo="$work/repo"
git init -q "$repo"
git -C "$repo" checkout -q -b main
mkdir -p "$repo/docs" "$repo/macos/Config"
cat >"$repo/docs/ok.md" <<'EOF'
PUBLIC_URL=https://relay.example.com
Add https://relay.example.com/mcp as a connector, or https://192-0-2-10.sslip.io/mcp.
"PUBLIC_URL": "http://localhost:8080"
PUBLIC_URL=https://$HOST and https://{{HOST}}/mcp and https://<name>/mcp
latchkey://paired?code=a&relay=https%3A%2F%2Frelay.example.com
Other servers are listed at https://servers.directory.net/mcp/servers.
A relay may run anywhere, say at some host in prose.
EOF
printf 'LATCHKEY_DEFAULT_RELAY_HOST =\nDEVELOPMENT_TEAM =\n' >"$repo/macos/Config/Base.xcconfig"
printf 'DEVELOPMENT_TEAM = ABCDE12345\n' >"$repo/macos/Config/Local.xcconfig.example"
printf 'xcodebuild LATCHKEY_DEFAULT_RELAY_HOST= build\n' >"$repo/package.sh"
git -C "$repo" add docs macos package.sh
commit -m "start"

run
is 0 "placeholders only pass, in a cloud session with no private values"

# expect_fail LABEL LINE: a tracked file with LINE fails, names the file, never prints the value.
expect_fail() {
  printf '%s\n' "$2" >"$repo/docs/bad.md"
  git -C "$repo" add docs/bad.md
  run
  is 1 "$1 fails"
  has 'docs/bad.md:1' "$1: names file and line"
  hasnt "private""zone\|$team" "$1: never prints the value"
  git -C "$repo" rm -q -f docs/bad.md
}
expect_fail "a relay's PUBLIC_URL" "PUBLIC_URL=https://$host"
expect_fail "a quoted PUBLIC_URL, any case" "\"public_url\": \"https://$upper\""
expect_fail "a connector URL" "Add https://$host/mcp in Claude."
expect_fail "a connector URL with a port" "https://$host:8443/mcp"
expect_fail "a pairing link" "latchkey://paired?code=a&relay=https%3A%2F%2F$host"
expect_fail "the app's default relay" "LATCHKEY_DEFAULT_RELAY_HOST = $host"
expect_fail "a signing team" "DEVELOPMENT_TEAM = $team"
expect_fail "a signing team in YAML" "DEVELOPMENT_TEAM: \"$team\""

run
is 0 "clean again once removed before committing"

# Commits a push would publish are checked: added lines and messages.
printf 'PUBLIC_URL=https://%s\n' "$host" >"$repo/docs/later.md"
git -C "$repo" add docs/later.md
commit -m "add"
git -C "$repo" rm -q docs/later.md
commit -m "remove"
run
is 1 "added and removed in commits not yet pushed fails"
has "commit $(git -C "$repo" rev-parse --short HEAD~1)" "names the commit that added it"
hasnt "private""zone" "never prints the host"

git -C "$repo" reset -q --hard HEAD~2
commit --allow-empty -m "see https://$host/mcp"
run
is 1 "a commit message naming a relay fails"
git -C "$repo" reset -q --hard HEAD~1

# Once on a remote, history is no longer this push's to check.
git init -q --bare "$work/origin.git"
printf 'PUBLIC_URL=https://%s\n' "$host" >"$repo/docs/later.md"
git -C "$repo" add docs/later.md
commit -m "add"
git -C "$repo" rm -q docs/later.md
commit -m "remove"
git -C "$repo" remote add origin "$work/origin.git"
git -C "$repo" push -q origin main 2>/dev/null
run
is 0 "commits already on a remote aren't checked again"

[ "$fails" = 0 ] && echo "private_values_test: all passed"
exit "$fails"
