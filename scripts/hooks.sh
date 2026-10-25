#!/bin/sh
# Claude Code hooks for this repository (wired in .claude/settings.json). Reads the hook's JSON on
# stdin. Toni, 2026-10-24: all work integrated into main and pushed, no work ever lost, never a
# cleanup he has to ask for.
#
#   hooks.sh session-start  Runs scripts/tidy.sh, then tells Claude about any loose ends.
#   hooks.sh stop           Before Claude ends a turn: if loose ends remain, sends it back once
#                           to resolve them (the second stop always goes through).
#   hooks.sh guard          Before a shell command: refuses git commands that can lose work.
#   hooks.sh after-bash     After a shell command: runs scripts/tidy.sh after every `git push`.
here=$(cd "$(dirname "$0")" && pwd)
input=$(cat)
field() { printf '%s' "$input" | jq -r "$1 // empty"; }

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
  cmd=$(field .tool_input.command)
  printf '%s' "$cmd" | grep -q 'git' || exit 0
  why=""
  if printf '%s' "$cmd" | grep -Eq 'git( -C [^ ]+)? stash( (push|save|pop|drop|clear)|( -[a-zA-Z-]+)*( *$|[;&|]))'; then
    why="git stash is shared by every worktree and invisible on GitHub; make a commit on your branch instead"
  elif printf '%s' "$cmd" | grep -Eq 'git( -C [^ ]+)? push.*( -f( |$)|--force|\+[A-Za-z0-9_./-]+:)'; then
    why="never force-push; rebase on origin/main and push normally"
  elif printf '%s' "$cmd" | grep -Eq 'git( -C [^ ]+)? (reset --hard|clean -[a-zA-Z]*f|branch -D|checkout -- |checkout \.( |$)|restore( --worktree)? \.)'; then
    why="this can throw away work; commit it (or move it to a branch) first, and delete only merged branches with git branch -d"
  fi
  [ -n "$why" ] || exit 0
  jq -n --arg r "Blocked by the repository's no-lost-work rule (CLAUDE.md): $why." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  ;;
after-bash)
  field .tool_input.command | grep -q 'git push' && "$here/tidy.sh"
  exit 0
  ;;
esac
exit 0
