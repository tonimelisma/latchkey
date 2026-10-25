#!/bin/sh
# Tests for `scripts/hooks.sh guard` (the check before each shell command from Claude Code).
# Run: scripts/tests/hooks_guard_test.sh (or `make -C relay script-tests`).
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
hooks="$root/scripts/hooks.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

# A clean repository to run in, and one that holds a private value.
for r in clean dirty; do
  git init -q "$work/$r"
  git -C "$work/$r" checkout -q -b main
  printf '.env\n' >"$work/$r/.gitignore"
  echo "DEPLOY_HOST=latch.privatezone.test" >"$work/$r/.env"
  echo hello >"$work/$r/file"
  git -C "$work/$r" add .gitignore file
  git -C "$work/$r" -c user.name=t -c user.email=t@example.com commit -q -m start
done
echo "see latch.privatezone.test" >"$work/dirty/file"

# guard <dir> <command>: prints the hook's answer.
guard() { jq -n --arg c "$2" --arg d "$1" '{cwd: $d, tool_input: {command: $c}}' | "$hooks" guard; }
denied() { if guard "$work/clean" "$1" | grep -q '"permissionDecision": *"deny"'; then ok "refused: $1"; else bad "should be refused: $1"; fi; }
allowed() { if [ -z "$(guard "$work/clean" "$1")" ]; then ok "allowed: $1"; else bad "should be allowed: $1"; fi; }

# Setting work aside in the shared stash, however it is spelled.
denied 'git stash'
denied 'git stash push -u -m wip'
denied 'git stash -u'
denied 'git stash -m "wip"'
denied 'git stash pop'
denied 'git -C /somewhere stash'
denied 'git -c core.editor=true stash'
denied 'git -c a=b -C /x --no-pager stash drop'
denied 'cd x && git stash; ls'
allowed 'git stash list'
allowed 'git -c color.ui=never stash show -p'
allowed 'git status'

# Force-pushing, however it is spelled.
denied 'git push --force'
denied 'git push -f origin main'
denied 'git push origin main -f'
denied 'git push -uf origin x'
denied 'git push --force-with-lease origin x'
denied 'git push origin +main'
denied 'git push origin +HEAD:main'
denied "git push origin '+HEAD:main'"
denied 'git -c push.default=current push origin +x'
denied 'git push \
  --force origin main'
allowed 'git push origin HEAD:main'
allowed 'git push -u origin feature-x'
allowed 'git push --follow-tags origin main'
allowed 'git push origin main && rm -f /tmp/x'
allowed 'git push origin main
echo "1 +2"'

# Throwing work away.
denied 'git reset --hard HEAD~1'
denied 'git -C x clean -fd'
denied 'git branch -D old'
denied 'git checkout -- .'
allowed 'git branch -d merged'
allowed 'git reset --soft HEAD~1'
allowed 'ls -la'

# A push is refused while a private value is in the repository.
out=$(guard "$work/dirty" 'git push origin HEAD:main')
if printf '%s' "$out" | grep -q '"permissionDecision": *"deny"'; then ok "push refused with a private value in a tracked file"; else bad "push refused with a private value in a tracked file"; fi
if printf '%s' "$out" | grep -q 'file:1'; then ok "refusal says where"; else bad "refusal says where"; fi
if printf '%s' "$out" | grep -qi 'privatezone'; then bad "refusal doesn't print the value"; else ok "refusal doesn't print the value"; fi
if [ -z "$(guard "$work/dirty" 'git status')" ]; then ok "other git commands are not held up by it"; else bad "other git commands are not held up by it"; fi
mkdir "$work/norepo"
if guard "$work/norepo" 'git push' | grep -q '"permissionDecision": *"deny"'; then ok "push refused when the check can't run"; else bad "push refused when the check can't run"; fi

# Without jq nothing can be read: git commands are refused with a reason, others go through.
mkdir "$work/nojq"
for tool in sh cat grep sed git dirname cut tail tr head awk; do ln -s "$(command -v "$tool")" "$work/nojq/$tool"; done
nojq() { printf '%s' "$1" | PATH="$work/nojq" /bin/sh "$hooks" guard; }
out=$(nojq '{"cwd":"/tmp","tool_input":{"command":"git stash"}}')
if printf '%s' "$out" | grep -q '"permissionDecision": *"deny"' && printf '%s' "$out" | grep -q jq; then
  ok "without jq a git command is refused, and the reason names jq"
else bad "without jq a git command is refused, and the reason names jq"; fi
if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then ok "that refusal is valid JSON"; else bad "that refusal is valid JSON"; fi
if [ -z "$(nojq '{"cwd":"/tmp","tool_input":{"command":"brew install jq"}}')" ]; then ok "without jq other commands are allowed"; else bad "without jq other commands are allowed"; fi

[ "$fails" = 0 ] && echo "all passed" || echo "$fails failed"
[ "$fails" = 0 ]
