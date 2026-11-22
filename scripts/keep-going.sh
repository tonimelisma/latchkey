#!/bin/sh
# Keep going (Toni, 2026-11-07: "add it, if you promise stop works"). Claude Code runs this when
# Claude is about to end a turn (the Stop hook, wired through scripts/hooks.sh keep-going). It
# reads the hook's JSON on stdin and sends Claude back to work while the session's work list has
# open items.
#
# The work list is a file Claude keeps per session (the transcript's folder changes when the
# session enters a worktree; the session ID doesn't):
#   ~/.claude/worklists/<session_id>.md
# with one item per line:
#   - [ ] open: Claude may not end the turn while any of these remains
#   - [x] done
#   - [toni] blocked on something only Toni can do (say what in the line)
# No file: nothing happens, so a session without a list is never held.
#
# Stop always works:
#   - Pressing Stop (Esc) is a user interrupt; Claude Code doesn't run Stop hooks then
#     (code.claude.com/docs/en/hooks).
#   - When Toni's latest message says stop, pause, or wait, the hook lets the turn end.
#   - Any failure here (no jq, unreadable input or transcript) lets the turn end.
#   - Claude Code itself ends the turn after 8 send-backs in a row.
# Claims need evidence (Toni, 2026-11-22: CLAUDE.md, "Done means Toni's conditions"): when no
# item is open and Claude's last message says something works, is fixed, or is done, but names no
# VERIFIED, NOT VERIFIED, or SCHEDULED row, the turn is sent back once (never again in the same
# chain of send-backs: stop_hook_active) to lead with the rows, or to end unchanged when the
# message claims nothing about one of Toni's conditions.
# Tested by scripts/tests/keep_going_test.sh.

input=$(cat) || exit 0
command -v jq >/dev/null 2>&1 || exit 0
session=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null) || exit 0
case "$session" in '' | */* | .*) exit 0 ;; esac
list="${KEEP_GOING_DIR:-$HOME/.claude/worklists}/$session.md"
[ -f "$list" ] || exit 0

# Toni's latest message: the last user entry with text of its own (tool results are user entries
# too, without text).
# Without the transcript there's no telling whether Toni said stop: let the turn end.
[ -f "$transcript" ] || exit 0
{
	# System notices and this hook's own feedback are user entries too: skip meta entries and text
	# that starts with "<" (a tag) or is hook feedback.
	# A message sent while Claude works is a queue entry ("enqueue"), counted from when it was sent.
	last=$(jq -rs '[.[]
		| if .type == "queue-operation" and .operation == "enqueue" then (.content // "")
		  elif .type == "user" and (.isMeta != true) and (.isCompactSummary != true) then
		    (.message.content | if type == "string" then . else ([.[]? | select(.type == "text") | .text] | join(" ")) end)
		  else empty end
		| select(type == "string" and length > 0)
		| select((startswith("<") or startswith("This session is being continued") or test("hook feedback"; "i")) | not)
		] | last // ""' "$transcript" 2>/dev/null) || last=""
	# "don't stop", "without stopping", "never stop" ask for the opposite: drop them first.
	# (Lower case first; the typographic apostrophe, U+2019, becomes a plain one.)
	asked=$(printf '%s' "$last" | tr '[:upper:]' '[:lower:]' | sed -E -e "s/$(printf '\342\200\231')/'/g" \
		-e "s/(don't|dont|do not|never|not|without|no) +(stop|stopping|pause|pausing|wait|waiting)//g")
	if printf '%s' "$asked" | grep -Eiq '(^|[^a-z])(stop|stopping|pause|wait|hold on|enough)([^a-z]|$)'; then
		exit 0
	fi
}

open=$(grep -E '^[[:space:]]*- \[ \]' "$list" 2>/dev/null)
if [ -z "$open" ]; then
	active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null) || exit 0
	[ "$active" = true ] && exit 0
	said=$(jq -rs '[.[] | select(.type == "assistant")
		| (.message.content | if type == "string" then . else ([.[]? | select(.type == "text") | .text] | join(" ")) end)
		| select(type == "string" and length > 0)] | last // ""' "$transcript" 2>/dev/null) || exit 0
	printf '%s' "$said" | grep -Eiq '(^|[^a-z])(works|working|fixed|done|signed in|succeeded)([^a-z]|$)' || exit 0
	printf '%s' "$said" | grep -Eq 'VERIFIED|SCHEDULED' && exit 0
	jq -n '{decision: "block", reason: "Your last message says something works, is fixed, or is done, without Toni'"'"'s condition rows (CLAUDE.md, \"Done means Toni'"'"'s conditions\"). If it is about something Toni asked to work, rewrite it to lead with each condition as VERIFIED (live run in that exact state: version, time, what was seen), NOT VERIFIED, or SCHEDULED. If it claims nothing of the kind, end the turn again unchanged."}'
	exit 0
fi
jq -n --arg r "Don't end the turn yet: the work list ($list) still has open items. Do the next one that can move forward without Toni. Mark an item [x] when done and verified, or [toni] with what only Toni can do; end the turn only when no [ ] items are left.
$open" '{decision: "block", reason: $r}'
