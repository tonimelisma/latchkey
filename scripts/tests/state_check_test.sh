#!/bin/sh
# Tests for the parts of macos/scripts/state-check/state-check.sh a cloud session uses to run the
# live checks with its own Latchkey tools (prompt, record, merge): no Mac, no Claude, only jq.
# Run: scripts/tests/state_check_test.sh (or `make -C relay script-tests`).
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
sc=$root/macos/scripts/state-check/state-check.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (wanted '$3', got '$2')"; fi; }

p=$(LATCHKEY_CHECK_TO=check@example.com bash "$sc" prompt notes "Latchkey check 1123-1000 locked" "Test Mac")
case $p in *'always pass machine: "Test Mac"'*) ok "the prompt names the machine" ;; *) bad "the prompt names the machine" ;; esac
case $p in *'notes.create_in_folder: notes_change create, title "Latchkey check 1123-1000 locked"'*) ok "with the group's cases and the tag filled in" ;; *) bad "with the group's cases and the tag filled in" ;; esac
case $p in *'{TAG}'* | *'{TOMORROW}'*) bad "no placeholder is left" ;; *) ok "no placeholder is left" ;; esac
bash "$sc" prompt notes t m >/dev/null 2>&1 && bad "without LATCHKEY_CHECK_TO the prompt is refused" || ok "without LATCHKEY_CHECK_TO the prompt is refused"
[ ! -e notes ] && [ ! -e "$root/notes" ] && ok "prompt makes no folder" || bad "prompt makes no folder"

cat >"$work/reply.txt" <<'R'
Done.
```json
[{"id": "messages.conversations", "result": "works", "note": ""},
 {"id": "messages.search", "result": "refused", "note": "locked"},
 {"id": "messages.read", "result": "works", "note": ""}]
```
R
bash "$sc" record "$work/results" locked messages "$work/reply.txt" locked locked 10:00:00 10:05:00
is "a reply is filed with its cases" "$(jq -r '.cases | length' "$work/results/locked/messages.json")" 3
is "and the states seen" "$(jq -c '.seen' "$work/results/locked/messages.json")" '["locked"]'
echo "no json here" >"$work/bad.txt"
bash "$sc" record "$work/results" locked files "$work/bad.txt" locked unlocked 10:05:00 10:06:00
is "a reply without results counts every case as failed" "$(jq -r '[.cases[] | .result] | unique | join(",")' "$work/results/locked/files.json")" failed
is "with both states seen" "$(jq -c '.seen' "$work/results/locked/files.json")" '["locked","unlocked"]'
out=$(bash "$sc" merge "$work/results" locked 0.8.230)
is "merge sums the results" "$(jq -r '.app' "$work/results/locked.result.json")" 0.8.230
case $out in *"works: 2"*) ok "and prints the totals" ;; *) bad "and prints the totals ($out)" ;; esac
bash "$sc" record "$root/x" locked messages "$work/reply.txt" locked locked 1 2 >/dev/null 2>&1 && bad "results inside the repository are refused" || ok "results inside the repository are refused"
rm -rf "$root/x"

[ "$fails" -eq 0 ] && echo "state_check_test: all passed" || { echo "state_check_test: $fails failed"; exit 1; }
