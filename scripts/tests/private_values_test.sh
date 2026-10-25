#!/bin/sh
# Tests for scripts/private-values-check.sh in a temporary repository with made-up values.
# Run: scripts/tests/private_values_test.sh (or `make -C relay script-tests`).
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
check="$root/scripts/private-values-check.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [ -f "$work/out" ] && sed 's/^/     /' "$work/out"; }
# run <dir>: runs the check there; output in $work/out, exit code in $code.
run() { (cd "$1" && "$check") >"$work/out" 2>&1; code=$?; }
is() { if [ "$code" = "$1" ]; then ok "$2"; else bad "$2 (exit $code, wanted $1)"; fi; }
has() { if grep -q -- "$1" "$work/out"; then ok "$2"; else bad "$2"; fi; }
hasnt() { if grep -qi -- "$1" "$work/out"; then bad "$2"; else ok "$2"; fi; }
commit() { git -C "$repo" -c user.name=t -c user.email=t@example.com commit -q "$@"; }

repo="$work/repo"
git init -q "$repo"
git -C "$repo" checkout -q -b main
mkdir -p "$repo/macos/Config" "$repo/docs"
printf '.env\nmacos/Config/Local.xcconfig\n' >"$repo/.gitignore"
echo "A relay at relay.example.com, in zone us-central9-z, on vm-1." >"$repo/docs/readme.md"
echo "bundleIdPrefix: test.privatezone" >"$repo/project.yml"
git -C "$repo" add .gitignore docs/readme.md project.yml
commit -m "start"

run "$repo"
is 0 "nothing to check without the private files"

cat >"$repo/.env" <<'EOF'
CLOUDFLARE_API_TOKEN=cf-secret-token-value
DEPLOY_HOST=latch.privatezone.test
DEPLOY_DNS_ZONE="privatezone.test"
DEPLOY_VM=vm-1
export DEPLOY_PROJECT='my-cloud-project'
DEPLOY_ZONE=us-central9-z
EOF
cat >"$repo/macos/Config/Local.xcconfig" <<'EOF'
// signing
DEVELOPMENT_TEAM = TEAM123XYZ // mine
LATCHKEY_DEFAULT_RELAY_HOST = latch.privatezone.test
EOF

run "$repo"
is 0 "clean repository passes"
hasnt 'vm-1\|us-central9-z' "short values and the cloud zone are not searched"

# The reversed zone (a bundle ID prefix) is fine; the forward form is not.
printf 'see https://Latch.PrivateZone.test/mcp\n' >>"$repo/docs/readme.md"
run "$repo"
is 1 "value in a tracked file fails, whatever its case"
has 'docs/readme.md:2' "names file and line"
has 'DEPLOY_HOST' "names the setting"
hasnt 'privatezone' "never prints the value"
git -C "$repo" checkout -q docs/readme.md

echo "team TEAM123XYZ" >"$repo/docs/team.md"
git -C "$repo" add docs/team.md
run "$repo"
is 1 "team ID in a newly added file fails"
has 'docs/team.md:1' "names the added file"
has 'DEVELOPMENT_TEAM' "names the team setting"
commit -m "add team"
git -C "$repo" rm -q docs/team.md
commit -m "remove team"
run "$repo"
is 1 "value removed from the files but still in history fails"
has "commit $(git -C "$repo" rev-parse --short HEAD~1)" "names the commit that added it"
hasnt 'TEAM123XYZ' "never prints the team ID"

# Start over without that history.
rm -rf "$repo/.git"
git init -q "$repo"
git -C "$repo" checkout -q -b main
git -C "$repo" add .gitignore docs/readme.md project.yml
commit -m "start"
run "$repo"
is 0 "fresh history passes"

commit --allow-empty -m "deployed to my-cloud-project"
run "$repo"
is 1 "value in a commit message fails"
has 'DEPLOY_PROJECT' "names the project setting"
git -C "$repo" reset -q --soft HEAD~1

git -C "$repo" checkout -q -b side
echo "zone privatezone.test" >"$repo/docs/side.md"
git -C "$repo" add docs/side.md
commit -m "side"
git -C "$repo" checkout -q main
run "$repo"
is 1 "value on another branch fails"
has 'DEPLOY_DNS_ZONE' "names the zone setting"
git -C "$repo" update-ref -d refs/heads/side
git -C "$repo" reflog expire --expire=now --all
run "$repo"
is 0 "passes again once that branch is gone"

# A worktree without its own copies of the private files uses the main checkout's.
git -C "$repo" worktree add -q "$work/wt" -b wt 2>/dev/null
echo "host latch.privatezone.test" >"$work/wt/docs/readme.md"
run "$work/wt"
is 1 "worktree is checked against the main checkout's private files"
has 'docs/readme.md:1' "names the worktree's file"

(cd "$work" && "$check") >"$work/out" 2>&1
code=$?
is 2 "outside a repository it fails as 'could not check'"

[ "$fails" = 0 ] && echo "all passed" || echo "$fails failed"
[ "$fails" = 0 ]
