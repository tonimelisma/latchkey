#!/bin/sh
# Claude Code hooks for this repository (wired in .claude/settings.json). Reads the hook's JSON on
# stdin. Toni, 2026-10-24: all work integrated into main and pushed, no work ever lost, never a
# cleanup he has to ask for.
#
#   hooks.sh session-start  Runs scripts/tidy.sh, then tells Claude about any loose ends.
#   hooks.sh stop           Before Claude ends a turn: if loose ends remain, sends it back once
#                           to resolve them. Not wired since 2026-11-04 (Toni removed the hook).
#   hooks.sh guard          Before a shell command: refuses git commands that can lose work
#                           (stash except list/show, force-push in any spelling, hard reset,
#                           ...), and any `git push` while scripts/private-values-check.sh
#                           finds one of the deployment's private values in the repository.
#                           A seat belt, not a wall; tested by scripts/tests/hooks_guard_test.sh.
#   hooks.sh after-bash     After a shell command: runs scripts/tidy.sh after every `git push`.
here=$(cd "$(dirname "$0")" && pwd)
input=$(cat)
field() { printf '%s' "$input" | jq -r "$1 // empty"; }

# Without jq the hook's input can't be read. The guard then refuses every command that mentions
# git (with the reason), rather than letting everything through.
if ! command -v jq >/dev/null 2>&1; then
  case "$1" in
  guard)
    printf '%s' "$input" | grep -q 'git' || exit 0
    printf '%s\n' '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "Blocked: scripts/hooks.sh needs jq to check git commands, and jq is not installed. Install it (brew install jq), then run the command again."}}'
    ;;
  session-start)
    echo "scripts/hooks.sh needs jq, which is not installed: the checks for unfinished work and private values are not running, and git commands are refused. Install it: brew install jq"
    ;;
  esac
  exit 0
fi

case "$1" in
session-start)
  "$here/tidy.sh" >/dev/null 2>&1
  ends=$("$here/loose-ends.sh" "$(field .cwd)")
  [ -n "$ends" ] || exit 0
  jq -n --arg c "Loose ends in this repository (CLAUDE.md, \"Nothing left behind\"). Resolve them before or alongside the user's request, without being asked:
$ends" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}'
  ;;
stop)
  [ "$(field .stop_hook_active)" = true ] && exit 0
  ends=$("$here/loose-ends.sh" "$(field .cwd)")
  [ -n "$ends" ] || exit 0
  jq -n --arg r "Before ending the turn, resolve these loose ends (CLAUDE.md, \"Nothing left behind\"): finished work merged into main and pushed; unfinished work committed and pushed to its branch and named in your reply; other sessions' leftovers integrated or, if unclear, reported to Toni.
$ends" '{decision: "block", reason: $r}'
  ;;
guard)
  # One line per command: a backslash at a line's end joins lines, other line breaks separate
  # commands like ";".
  cmd=$(field .tool_input.command | sed -e ':a' -e '/\\$/N' -e 's/\\\n/ /' -e 'ta' | tr '\n' ';')
  printf '%s' "$cmd" | grep -q 'git' || exit 0
  # "git", then any options before the subcommand (-C dir, -c name=value, --no-pager, ...).
  g='git( +(-[cC] +[^ ]+|--[a-z-]+(=[^ ]+)?))*'
  end='( |$|[;&|)"'"'"'])'
  has() { printf '%s' "$cmd" | grep -Eq -- "$1"; }
  why=""
  if printf '%s' "$cmd" | sed -E "s/$g +stash +(list|show)//g" | grep -Eq -- "$g +stash$end"; then
    why="Blocked by the repository's no-lost-work rule (CLAUDE.md): git stash is shared by every worktree and invisible on GitHub; make a commit on your branch instead (only git stash list and show are allowed)"
  elif has "$g +push( [^;&|]*)? +(-[a-zA-Z]*f[a-zA-Z]*|--force[a-z-]*(=[^ ;&|]*)?)$end" ||
    has "$g +push( [^;&|]*)? +[\"']?\\+[^ ;&|]"; then
    why="Blocked by the repository's no-lost-work rule (CLAUDE.md): never force-push (-f, --force, or a +refspec); rebase on origin/main and push normally"
  elif has "$g +(reset +--hard|clean +-[a-zA-Z]*f|branch +-D|checkout +-- |checkout +\\.( |\$|;)|restore( +--worktree)? +\\.)"; then
    why="Blocked by the repository's no-lost-work rule (CLAUDE.md): this can throw away work; commit it (or move it to a branch) first, and delete only merged branches with git branch -d"
  elif has "$g +push$end"; then
    # Nothing is pushed while a private value of this deployment is in the repository.
    dir=$(field .cwd)
    [ -d "$dir" ] || dir=$here
    if ! found=$(cd "$dir" && "$here/private-values-check.sh" 2>&1); then
      why="Push blocked: the private-values check (scripts/private-values-check.sh) did not pass. Fix this, then push again:
$found"
    fi
  fi
  [ -n "$why" ] || exit 0
  jq -n --arg r "$why." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  ;;
after-bash)
  field .tool_input.command | grep -q 'git push' && "$here/tidy.sh"
  exit 0
  ;;
esac
exit 0
