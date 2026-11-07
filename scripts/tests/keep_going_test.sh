#!/bin/sh
# Tests for scripts/keep-going.sh: it sends Claude back only while the session's work list has
# open items, and every way of stopping still ends the turn.
# Run: scripts/tests/keep_going_test.sh (or `make -C relay script-tests`).
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

export KEEP_GOING_DIR="$work/lists"
mkdir -p "$KEEP_GOING_DIR"
sid=sess-1
list="$KEEP_GOING_DIR/$sid.md"
tr="$work/t.jsonl"

# The last user message, as Claude Code writes it.
said() { jq -cn --arg c "$1" '{type: "user", message: {role: "user", content: $c}}' >>"$tr"; }
queued() { jq -cn --arg c "$1" '{type: "queue-operation", operation: "enqueue", content: $c}' >>"$tr"; }
hook() { jq -cn --arg s "$sid" --arg t "$tr" '{session_id: $s, transcript_path: $t, stop_hook_active: false}' | "$root/scripts/keep-going.sh"; }
blocks() { if [ "$(hook | jq -r .decision)" = block ]; then ok "$1"; else bad "$1"; fi; }
lets_end() { if [ -z "$(hook)" ]; then ok "$1"; else bad "$1"; fi; }

: >"$tr"
said "finish everything"
lets_end "no work list: the turn ends"

printf -- '- [ ] sweep the old messages\n- [x] fix the flaky test\n' >"$list"
blocks "an open item sends Claude back"
if hook | jq -r .reason | grep -q 'sweep the old messages'; then ok "the reason names the open item"; else bad "the reason names the open item"; fi

printf -- '- [x] sweep\n- [toni] unlock the Mac\n' >"$list"
lets_end "only done and Toni-only items: the turn ends"

printf -- '- [ ] sweep\n' >"$list"
for m in "stop" "STOP!" "please stop now" "Stop working on this" "pause" "wait" "hold on" "ok enough"; do
	: >"$tr"
	said "$m"
	lets_end "Toni says \"$m\": the turn ends"
done

for m in "don't stop" "don’t stop until it's done" "never stop" "keep going without stopping" "go, do not stop"; do
	: >"$tr"
	said "$m"
	blocks "Toni says \"$m\": Claude is sent back"
done

: >"$tr"
said "keep going"
queued "stop"
lets_end "a stop sent while Claude works ends the turn"

: >"$tr"
said "stop"
said "<system-reminder>notice</system-reminder>"
jq -cn '{type: "user", message: {content: [{type: "tool_result", content: "x"}]}}' >>"$tr"
lets_end "notices and tool results don't hide Toni's stop"

: >"$tr"
said "stop"
said "go on"
blocks "a later message overrides an earlier stop"

lets_end_raw() { if [ -z "$(printf '%s' "$2" | "$root/scripts/keep-going.sh")" ]; then ok "$1"; else bad "$1"; fi; }
lets_end_raw "unreadable input: the turn ends" "not json"
lets_end_raw "no session id: the turn ends" '{"transcript_path": "x"}'
lets_end_raw "a session id with a slash: the turn ends" '{"session_id": "../x", "transcript_path": "x"}'
if jq -cn --arg s "$sid" '{session_id: $s, transcript_path: "/nonexistent.jsonl"}' | "$root/scripts/keep-going.sh" | grep -q .; then bad "no transcript: the turn ends"; else ok "no transcript: the turn ends"; fi

if [ "$fails" -ne 0 ]; then echo "$fails failed"; exit 1; fi
echo "all keep-going tests pass"
