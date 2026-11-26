#!/bin/sh
# Tests for what scripts/hooks.sh does in a Claude Code cloud session (CLAUDE_CODE_REMOTE=true)
# and that nothing changes without it: session-start runs cloud-setup.sh and skips tidy.sh,
# after-bash skips tidy.sh, the guard refuses the same commands. hooks.sh runs from a copy whose
# neighbours (tidy, loose-ends, cloud-setup, private-values-check) are stand-ins that leave a mark.
# Run: scripts/tests/hooks_cloud_test.sh (or `make -C relay script-tests`).
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

s="$work/scripts"
mkdir -p "$s"
cp "$root/scripts/hooks.sh" "$s/"
for n in tidy loose-ends cloud-setup; do
  printf '#!/bin/sh\necho %s >>"%s/ran"\n' "$n" "$work" >"$s/$n.sh"
done
printf '\necho "loose end: 1 uncommitted change"\n' >>"$s/loose-ends.sh"
printf '\necho "cloud setup: installed jq"\n' >>"$s/cloud-setup.sh"
printf '#!/bin/sh\necho private-values-check >>"%s/ran"\nexit 0\n' "$work" >"$s/private-values-check.sh"
chmod +x "$s"/*.sh

# hook <event> <command> [remote]: runs the hook; output in $out, what ran in $ran.
hook() {
  rm -f "$work/ran"
  out=$(jq -n --arg c "$2" --arg d "$work" '{cwd: $d, tool_input: {command: $c}}' |
    env -u CLAUDE_CODE_REMOTE ${3:+CLAUDE_CODE_REMOTE=$3} "$s/hooks.sh" "$1")
  # shellcheck disable=SC2034 # read by the checks, through eval
  ran=$(tr '\n' ' ' 2>/dev/null <"$work/ran")
}
denied() { printf '%s' "$out" | grep -q '"permissionDecision": *"deny"'; }

# Session start.
hook session-start ''
check "on the Mac, session start tidies and reports loose ends" '[ "$ran" = "tidy loose-ends " ]'
check "on the Mac, the loose ends reach Claude" 'printf "%s" "$out" | jq -r .hookSpecificOutput.additionalContext | grep -q "loose end: 1"'
check "on the Mac, no word of a cloud session" '! printf "%s" "$out" | grep -q "cloud"'
hook session-start '' true
check "in the cloud, session start sets up, skips tidy, reports loose ends" '[ "$ran" = "cloud-setup loose-ends " ]'
# shellcheck disable=SC2034 # read by the checks, through eval
ctx=$(printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext)
check "in the cloud, Claude hears it is a cloud session" 'printf "%s" "$ctx" | grep -q "Two ways to work"'
check "in the cloud, Claude hears what setup did" 'printf "%s" "$ctx" | grep -q "installed jq"'
check "in the cloud, Claude hears the loose ends" 'printf "%s" "$ctx" | grep -q "loose end: 1"'
hook session-start '' false
check "CLAUDE_CODE_REMOTE other than true counts as the Mac" '[ "$ran" = "tidy loose-ends " ]'

# After a push.
hook after-bash 'git push origin HEAD:main'
check "on the Mac, a push is followed by tidy" '[ "$ran" = "tidy " ]'
hook after-bash 'git push origin HEAD:main' true
check "in the cloud, a push is not followed by tidy" '[ -z "$ran" ]'
hook after-bash 'ls' true
check "in the cloud, other commands run nothing" '[ -z "$ran" ]'

# The guard is the same in both.
for remote in '' true; do
  where=${remote:+in the cloud}
  where=${where:-on the Mac}
  hook guard 'git stash' "$remote"
  check "$where, git stash is refused" denied
  hook guard 'git push --force origin main' "$remote"
  check "$where, force-push is refused" denied
  hook guard 'git reset --hard HEAD~1' "$remote"
  check "$where, a hard reset is refused" denied
  hook guard 'git push origin HEAD:main' "$remote"
  check "$where, a push runs the private-values check" '[ "$ran" = "private-values-check " ] && [ -z "$out" ]'
done

# A push the private-values check can't clear is refused in the cloud too.
printf '#!/bin/sh\necho "cannot check" >&2\nexit 2\n' >"$s/private-values-check.sh"
hook guard 'git push origin HEAD:main' true
check "in the cloud, a push is refused when the private-values check fails" denied

[ "$fails" = 0 ] && echo "all passed" || echo "$fails failed"
[ "$fails" = 0 ]
