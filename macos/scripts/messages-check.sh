#!/bin/bash
# Runs Latchkey's real Messages window code (scripts/messages-check/main.swift) against the real
# Messages, only in conversations of the owner with himself: a named group of his own address and
# number, a tapback given and taken back, an inline reply, an edit, an unsend, a deletion. Whatever
# happens, the sweep then deletes every message the run made (and the group), checks Messages'
# database, and fails loudly naming anything left.
# Run it from a terminal that has Accessibility, with the Mac unlocked.
# Usage: messages-check.sh <own address> <own number> [run|sweep] [tag]
# MESSAGES_CHECK_DB: Messages' database or a fresh copy of it (the terminal needs Full Disk Access
# to read the real one).
set -euo pipefail
cd "$(dirname "$0")/.."
address=${1:?own address}
number=${2:?own number}
mode=${3:-run}
tag=${4:-"Latchkey check $(date +%m%d-%H%M) msgcheck"}
out=$(mktemp -d)
cleanup() {
    local status=$?
    if [[ $mode == run && -x $out/messages-check ]]; then
        "$out/messages-check" sweep "$tag" "$address" "$number" || status=1
    fi
    rm -rf "$out"
    exit "$status"
}
trap cleanup EXIT
swiftc -O -swift-version 6 -o "$out/messages-check" \
    App/Foreground.swift App/Messages/MessagesWindow.swift App/Messages/MessagesStore.swift App/Messages/AttributedBody.swift \
    App/Messages/Contacts.swift App/SQLite.swift App/ImagePrep.swift App/Computer/Screen.swift \
    scripts/messages-check/main.swift
if [[ $mode == sweep ]]; then
    "$out/messages-check" sweep "$tag" "$address" "$number"
else
    MESSAGES_CHECK_TAG=$tag "$out/messages-check" run "$address" "$number"
fi
