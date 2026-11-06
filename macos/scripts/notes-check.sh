#!/bin/bash
# Runs Latchkey's real Notes window code against the real Notes (scripts/notes-check/main.swift),
# so checklist editing is proven on a real Mac before it ships. Run from a terminal that has
# Accessibility. Make test notes titled "Latchkey check …" only, and delete them afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -O -swift-version 6 -o "$out/notes-check" \
    App/Notes/NoteWindow.swift App/Notes/NotesWindowRoute.swift App/Notes/NoteHTML.swift \
    scripts/notes-check/stubs.swift scripts/notes-check/main.swift
"$out/notes-check" "$@"
