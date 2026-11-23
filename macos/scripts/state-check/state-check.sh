#!/bin/bash
# Tries every use case in cases.json through the hosted relay with a fresh Claude Code (signed in
# with the owner's subscription), in each screen state: unlocked, locked, lid closed (still
# unlocked), lid closed and locked. The display asleep on an unlocked Mac is left out (Toni,
# 2026-11-04): it lasts only the minutes before the screen lock and in practice never comes up.
#
#   state-check.sh run <results dir> [group…]  a run (all groups, or those named) in the state now
#   state-check.sh wait <results dir> [days]   runs each state not yet tried as soon as the Mac is
#                                              in it; ends when all four are done (default 4 days)
#   state-check.sh report <results dir>        writes docs/use-cases.md from the results
#
# A cloud session (claude.ai/code, with the Latchkey connector) runs the cases itself instead of
# `claude -p`, with these, which need only jq (docs/cloud-sessions.md, "Live checks"):
#   state-check.sh prompt <group> <tag> <machine>      the exact instructions a run gets
#   state-check.sh record <results dir> <state> <group> <reply file> <before> <after> <from> <to>
#                                              files a reply (ending in the ```json block) as
#                                              that group's result in that state
#   state-check.sh merge <results dir> <state> <app version>   that state's result file
#
# The results folder must be outside the repository (Claude Code run inside a worktree would run
# the project's end-of-turn hooks). Results hold only works/refused/failed and a short reason.
# LATCHKEY_CHECK_TO: the owner's own address, for the cases that need it (marked as checks).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(git -C "$here" rev-parse --show-toplevel 2>/dev/null || echo /nonexistent)"
cases="$here/cases.json"
states=(unlocked locked lid_closed lid_closed_locked)

usage() { sed -n 6,18p "$0" >&2; exit 2; }
[[ $# -ge 2 ]] || usage
cmd=$1
if [[ $cmd != prompt ]]; then
    dir=$(mkdir -p "$2" && cd "$2" && pwd)
    case "$dir/" in "$repo"/*) echo "The results folder must be outside the repository." >&2; exit 2 ;; esac
fi

screen_state() { swift "$here/screen-state.swift"; }

# make_prompt <group> <tag> <machine>: the instructions for one capability's cases.
make_prompt() {
    local group=$1 tag=$2 mac=$3 tomorrow
    tomorrow=$(date -v+1d +%Y-%m-%d 2>/dev/null || date -d tomorrow +%Y-%m-%d)
    jq -r --arg g "$group" --arg tag "$tag" --arg to "$LATCHKEY_CHECK_TO" --arg day "$tomorrow" --arg mac "$mac" '
        .groups[] | select(.id == $g) |
        "You are running an automated check of Latchkey, unattended. Use only Latchkey tools and always pass machine: \"\($mac)\". Do the cases below in order without asking anything. Test data you make is named with the tag \"\($tag)\" (in notes, file names, events, cards, subjects); cleaning it up is part of the cases.\n\nFor each case record one result:\n- works: the tool did what the case asks (check its answer says so).\n- refused: the tool answered plainly that it can'\''t do this now, for example because the screen is off, asleep, or locked.\n- failed: an error, a timeout, a wrong or empty result, or a refusal that gives no clear reason.\n- skipped: it needed something an earlier case didn'\''t produce.\nIn note, give the tool'\''s own reason for refused or failed, at most 25 words, and never personal content (no names, addresses, subjects, or message, note, or file text).\n\nCases:\n" +
        ([.cases[] | "- \(.id): \(.steps)"] | join("\n") | gsub("\\{TAG\\}"; $tag) | gsub("\\{TO\\}"; $to) | gsub("\\{TOMORROW\\}"; $day)) +
        "\n\nEnd your reply with exactly one ```json block: an array with one object per case, in order: {\"id\": \"...\", \"result\": \"works|refused|failed|skipped\", \"note\": \"...\"}."
    ' "$cases"
}

# record_group <state> <group> <reply file> <before> <after> <from> <to>: the reply's ```json
# block as <dir>/<state>/<group>.json, or every case "failed" when there is none.
record_group() {
    local state=$1 group=$2 reply=$3 before=$4 after=$5 from=$6 to=$7 out="$dir/$1"
    mkdir -p "$out"
    if awk '/^```json/{on=1; next} /^```/{on=0} on' "$reply" | jq -e --arg b "$before" --arg a "$after" \
        --arg f "$from" --arg t "$to" \
        'if type == "array" and length > 0 then {seen: [$b, $a] | unique, from: $f, to: $t, cases: .} else error("no cases") end' \
        >"$out/$group.json" 2>/dev/null && [[ -s $out/$group.json ]]; then
        return 0
    fi
    jq -n --arg b "$before" --arg a "$after" --arg g "$group" --slurpfile c "$cases" \
            --arg f "$from" --arg t "$to" \
            '{seen: [$b, $a] | unique, from: $f, to: $t, cases: [$c[0].groups[] | select(.id == $g) | .cases[] |
              {id, result: "failed", note: "The check run itself didn'\''t finish or report"}]}' >"$out/$group.json"
}

# merge_state <state> <app version>: that state's groups into <dir>/<state>.result.json.
merge_state() {
    jq -s --arg s "$1" --arg t "$(date '+%F %T')" --arg v "$2" \
        '{state: $s, finished: $t, app: $v, cases: (map(.seen as $seen | .cases[] | . + {seen: $seen}))}' \
        "$dir/$1"/*.json >"$dir/$1.result.json"
    jq -r '.cases | group_by(.result) | map("\(.[0].result): \(length)") | join(", ")' "$dir/$1.result.json"
}

# One capability's cases in one Claude Code run; writes <dir>/<state>/<group>.json.
run_group() {
    local state=$1 group=$2 tag=$3 out="$dir/$1"
    local mac prompt
    mac=$(scutil --get ComputerName)
    prompt=$(make_prompt "$group" "$tag" "$mac")
    local before after from
    before=$(screen_state)
    from=$(date +%T)
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
    jq -r '.result // empty' "$out/$group.raw.txt" 2>/dev/null >"$out/$group.reply.txt" || : >"$out/$group.reply.txt"
    record_group "$state" "$group" "$out/$group.reply.txt" "$before" "$after" "$from" "$(date +%T)"
    rm -f "$out/$group.reply.txt"
}

# Removes every test item any run left (the sweep group, by the tag's common start, "Latchkey
# check"), and fails loudly, naming what stayed, unless the sweep found everything gone.
sweep() {
    local state=$1 watcher=$2
    trap - EXIT
    "$0" group "$dir" "$state" sweep "Latchkey check"
    kill "$watcher" 2>/dev/null || true
    local left
    left=$(jq -r '.cases[] | select(.result != "works") | "- \(.id): \(.note)"' "$dir/$state/sweep.json" 2>/dev/null ||
        echo "- the sweep didn't report")
    if [[ -n $left ]]; then
        echo "TEST ITEMS LEFT IN THE OWNER'S APPS:" >&2
        echo "$left" >&2
        return 1
    fi
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
    # What disturbed the person at the Mac, with the time; each group's from/to says whose it was.
    # One group at a time (LATCHKEY_CHECK_PARALLEL=1) makes that unambiguous.
    swiftc -O -o "$dir/focus-watch" "$here/focus-watch.swift"
    "$dir/focus-watch" >"$dir/$state/focus.log" 2>&1 &
    local watcher=$!
    # Last, every time, also when the run fails or is stopped: whatever this or an earlier run left
    # in the Owner's apps is found by the tag's common start and removed, then looked up again
    # (2026-11-02: ten Notes folders a run had "deleted" were still there; 2026-11-04: stopped
    # runs had left notes, mail, and reminders, since the sweep ran only after a whole run).
    trap 'sweep "$state" "$watcher"' EXIT
    trap 'exit 130' INT TERM
    if (($#)); then printf '%s\n' "$@"; else jq -r '.groups[].id' "$cases"; fi | grep -vx sweep |
        xargs -P "${LATCHKEY_CHECK_PARALLEL:-2}" -I{} "$0" group "$dir" "$state" {} "$tag"
    trap - EXIT INT TERM
    local swept=0
    sweep "$state" "$watcher" || swept=1
    merge_state "$state" "$(defaults read /Applications/Latchkey.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo unknown)"
    return "$swept"
}

report() {
    local files=()
    for s in "${states[@]}"; do [[ -f "$dir/$s.result.json" ]] && files+=("$dir/$s.result.json"); done
    {
        cat <<'EOF'
# What Latchkey can do, and when

Every use case Claude has on a Mac, tried through the hosted relay by a fresh Claude Code in
each screen state: unlocked, locked (screen on), lid closed while still unlocked (the first minutes), and lid closed and locked.
The display asleep on an unlocked Mac isn't a state of its own: it lasts only the minutes before the
screen lock, and on Toni's Mac it never came up in a day of waiting (dropped by Toni, 2026-11-04).
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
            ["unlocked", "locked", "lid_closed", "lid_closed_locked"] as $order |
            ($runs | map({key: .state, value: .}) | from_entries) as $by |
            "Checked: " + ([$order[] | "\(.): \($by[.].finished // "not yet")\($by[.].app // null | if . then " (app \(.))" else "" end)"] | join("; ")) + ".\n",
            "| Use case | Unlocked | Locked | Lid closed | Lid closed, locked |\n|---|---|---|---|---|",
            ($c[0].groups[] | . as $g |
                "| **\($g.name)** | | | | |",
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
prompt)
    : "${LATCHKEY_CHECK_TO:?set LATCHKEY_CHECK_TO to the address to send checks to}"
    make_prompt "$2" "${3:?tag}" "${4:?machine}" ;;
record) record_group "${3:?state}" "${4:?group}" "${5:?reply file}" "${6:?before}" "${7:?after}" "${8:?from}" "${9:?to}" ;;
merge) merge_state "${3:?state}" "${4:?app version}" ;;
run) run_all "${@:3}" ;;
wait)
    days=${3:-4}
    end=$(($(date +%s) + days * 86400))
    while (($(date +%s) < end)); do
        missing=0
        for s in "${states[@]}"; do [[ -f "$dir/$s.result.json" ]] || missing=1; done
        ((missing)) || { echo "All four states done."; exit 0; }
        # A state counts once it has held for two looks a minute apart (a lid shut for a moment
        # isn't "lid closed").
        s=$(screen_state)
        if [[ "$s" == "${last:-}" && " ${states[*]} " == *" $s "* && ! -f "$dir/$s.result.json" ]]; then run_all; fi
        last=$s
        sleep 60
    done
    echo "Stopped after $days days." ;;
report) report ;;
*) usage ;;
esac
