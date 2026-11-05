#!/bin/bash
# Runs Latchkey's real Reminders window and database code (scripts/reminders-check/main.swift)
# against the real Reminders, in whatever screen state the Mac is in, to see that subtasks, tags,
# and flags work there and that EventKit changes keep them. It makes one "Latchkey check … reminders"
# list and deletes it again, also when it fails or is stopped, and fails if anything is left.
# Needs Reminders access, Accessibility, and Full Disk Access: run it from a program that has them
# (Latchkey's shell tool has all three: build here with `reminders-check.sh build`, then run the
# printed binary through it with uses: open). Usage: reminders-check.sh [build]
set -euo pipefail
cd "$(dirname "$0")/.."
out="${REMINDERS_CHECK_OUT:-$(mktemp -d)}"
swiftc -O -swift-version 5 -o "$out/reminders-check" \
    App/Reminders/RemindersWindow.swift App/Reminders/RemindersStore.swift App/SQLite.swift \
    scripts/reminders-check/stubs.swift scripts/reminders-check/main.swift
if [ "${1:-}" = build ]; then
    echo "$out/reminders-check"
    exit 0
fi
trap 'rm -rf "$out"' EXIT
"$out/reminders-check"
