#!/bin/bash
# Tries every use case in cases.json through the hosted relay with a fresh Claude Code (signed in
# with the owner's subscription), in each screen state: unlocked, locked, screen asleep, lid closed
# (still unlocked), lid closed and locked.
#
#   state-check.sh run <results dir> [group…]  a run (all groups, or those named) in the state now
#   state-check.sh wait <results dir> [days]   runs each state not yet tried as soon as the Mac is
#                                              in it; ends when all five are done (default 4 days)
#   state-check.sh report <results dir>        writes docs/use-cases.md from the results
#
# The results folder must be outside the repository (Claude Code run inside a worktree would run
# the project's end-of-turn hooks). Results hold only works/refused/failed and a short reason.
# LATCHKEY_CHECK_TO: the owner's own address; mail and iMessages are sent there, marked as checks.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(git -C "$here" rev-parse --show-toplevel 2>/dev/null || echo /nonexistent)"
cases="$here/cases.json"
states=(unlocked locked screen_asleep lid_closed lid_closed_locked)

usage() { sed -n 6,9p "$0" >&2; exit 2; }
[[ $# -ge 2 ]] || usage
cmd=$1
dir=$(mkdir -p "$2" && cd "$2" && pwd)
case "$dir/" in "$repo"/*) echo "The results folder must be outside the repository." >&2; exit 2 ;; esac

screen_state() { swift "$here/screen-state.swift"; }

# One capability's cases in one Claude Code run; writes <dir>/<state>/<group>.json.
run_group() {
    local state=$1 group=$2 tag=$3 out="$dir/$1"
    local mac tomorrow prompt
    mac=$(scutil --get ComputerName)
    tomorrow=$(date -v+1d +%Y-%m-%d)
    prompt=$(jq -r --arg g "$group" --arg tag "$tag" --arg to "$LATCHKEY_CHECK_TO" --arg day "$tomorrow" --arg mac "$mac" '
        .groups[] | select(.id == $g) |
        "You are running an automated check of Latchkey, unattended. Use only Latchkey tools and always pass machine: \"\($mac)\". Do the cases below in order without asking anything. Test data you make is named with the tag \"\($tag)\" (in notes, file names, events, cards, subjects); cleaning it up is part of the cases.\n\nFor each case record one result:\n- works: the tool did what the case asks (check its answer says so).\n- refused: the tool answered plainly that it can'\''t do this now, for example because the screen is off, asleep, or locked.\n- failed: an error, a timeout, a wrong or empty result, or a refusal that gives no clear reason.\n- skipped: it needed something an earlier case didn'\''t produce.\nIn note, give the tool'\''s own reason for refused or failed, at most 25 words, and never personal content (no names, addresses, subjects, or message, note, or file text).\n\nCases:\n" +
        ([.cases[] | "- \(.id): \(.steps)"] | join("\n") | gsub("\\{TAG\\}"; $tag) | gsub("\\{TO\\}"; $to) | gsub("\\{TOMORROW\\}"; $day)) +
        "\n\nEnd your reply with exactly one ```json block: an array with one object per case, in order: {\"id\": \"...\", \"result\": \"works|refused|failed|skipped\", \"note\": \"...\"}."
    ' "$cases")
    local before after
    before=$(screen_state)
    # A Claude Code session sometimes starts without the claude.ai connector's tools; try again.
    prompt="If you have no Latchkey tools at all (search for them first), reply only NO_LATCHKEY_TOOLS.
$prompt"
    local try
    for try in 1 2 3; do
        (cd "$dir" && perl -e 'alarm shift; exec @ARGV' 1800 \
            claude -p "$prompt" --model sonnet --allowedTools mcp__claude_ai_Latchkey \
            --disallowedTools Bash Edit Write WebFetch WebSearch --output-format json </dev/null) >"$out/$group.raw.txt" 2>"$out/$group.err" || true
        grep -qE 'NO_LATCHKEY_TOOLS|not available in this session' "$out/$group.raw.txt" || break
        echo "$group: no Latchkey tools in try $try" >&2
        sleep 30
    done
    after=$(screen_state)
    jq -r '.result // empty' "$out/$group.raw.txt" 2>/dev/null |
        awk '/^```json/{on=1; next} /^```/{on=0} on' | jq --arg b "$before" --arg a "$after" \
        '{seen: [$b, $a] | unique, cases: .}' >"$out/$group.json" 2>/dev/null ||
        jq -n --arg b "$before" --arg a "$after" --arg g "$group" --slurpfile c "$cases" \
            '{seen: [$b, $a] | unique, cases: [$c[0].groups[] | select(.id == $g) | .cases[] |
              {id, result: "failed", note: "The check run itself didn'\''t finish or report"}]}' >"$out/$group.json"
}

# Runs the groups given (all when none) in the current state, then merges that state's results.
run_all() {
    : "${LATCHKEY_CHECK_TO:?set LATCHKEY_CHECK_TO to the address to send checks to}"
    export LATCHKEY_CHECK_TO
    local state tag
    state=$(screen_state)
    tag="Latchkey check $(date +%m%d-%H%M) $state"
    mkdir -p "$dir/$state"
    echo "$(date '+%F %T') running in state $state"
    if (($#)); then printf '%s\n' "$@"; else jq -r '.groups[].id' "$cases"; fi |
        xargs -P 2 -I{} "$0" group "$dir" "$state" {} "$tag"
    jq -s --arg s "$state" --arg t "$(date '+%F %T')" \
        --arg v "$(defaults read /Applications/Latchkey.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo unknown)" \
        '{state: $s, finished: $t, app: $v, cases: (map(.seen as $seen | .cases[] | . + {seen: $seen}))}' \
        "$dir/$state"/*.json >"$dir/$state.result.json"
    jq -r '.cases | group_by(.result) | map("\(.[0].result): \(length)") | join(", ")' "$dir/$state.result.json"
}

report() {
    local files=()
    for s in "${states[@]}"; do [[ -f "$dir/$s.result.json" ]] && files+=("$dir/$s.result.json"); done
    {
        cat <<'EOF'
# What Latchkey can do, and when

Every use case Claude has on a Mac, tried through the hosted relay by a fresh Claude Code in
each screen state: unlocked, locked (screen on), screen asleep (lid open), lid closed while still unlocked (the first minutes), and lid closed and locked.
Generated by `macos/scripts/state-check/state-check.sh report` from a real run; the cases are
in `macos/scripts/state-check/cases.json`. ✅ works, ⛔ refuses and says why, ❌ fails,
↷ not tried because an earlier step failed, — not run in that state yet.

EOF
        jq -r -n --slurpfile c "$cases" '
            def cell: gsub("\\|"; "/") | gsub("\n"; " ");
            def mark: if . == null then "—" elif .result == "works" then "✅"
                elif .result == "refused" then "⛔ \(.note | cell)" elif .result == "skipped" then "↷ \(.note | cell)"
                else "❌ \(.note | cell)" end;
            [inputs] as $runs |
            ["unlocked", "locked", "screen_asleep", "lid_closed", "lid_closed_locked"] as $order |
            ($runs | map({key: .state, value: .}) | from_entries) as $by |
            "Checked: " + ([$order[] | "\(.): \($by[.].finished // "not yet")\($by[.].app // null | if . then " (app \(.))" else "" end)"] | join("; ")) + ".\n",
            "| Use case | Unlocked | Locked | Screen asleep | Lid closed | Lid closed, locked |\n|---|---|---|---|---|---|",
            ($c[0].groups[] | . as $g |
                "| **\($g.name)** | | | | | |",
                ($g.cases[] | . as $case |
                    "| \($case.case) | " + ([$order[] | ($by[.].cases // [] | map(select(.id == $case.id)) | .[0]) | mark] | join(" | ")) + " |")),
            "\n## Not offered\n",
            ($c[0].groups[] | select(.missing | length > 0) | "- \(.name): \(.missing | join("; "))")
        ' ${files[@]+"${files[@]}"} </dev/null
    } >"$repo/docs/use-cases.md"
    echo "Wrote $repo/docs/use-cases.md"
}

case "$cmd" in
group) run_group "$3" "$4" "$5" ;;
run) run_all "${@:3}" ;;
wait)
    days=${3:-4}
    end=$(($(date +%s) + days * 86400))
    while (($(date +%s) < end)); do
        missing=0
        for s in "${states[@]}"; do [[ -f "$dir/$s.result.json" ]] || missing=1; done
        ((missing)) || { echo "All five states done."; exit 0; }
        # A state counts once it has held for two looks a minute apart (a lid shut for a moment
        # isn't "lid closed").
        s=$(screen_state)
        if [[ "$s" == "${last:-}" && ! -f "$dir/$s.result.json" ]]; then run_all; fi
        last=$s
        sleep 60
    done
    echo "Stopped after $days days." ;;
report) report ;;
*) usage ;;
esac
