# 0044. Changing

- Status: accepted
- Date: 2026-10-22
- Alias: plan 003 D3 (`specs/003-files/plan.md`, "D3. Changing")

## Context and problem

Decision D3 of spec 003's plan (Files); requirements in
[requirements/files.md](../requirements/files.md). Requirement IDs it cites: FR-213, FR-214, FR-208, FR-210.
The design it belongs to: [design/files.md](../design/files.md).

## Decision


FileManager for writes (atomic for new and replaced files), folders, moves, copies, and
`trashItem` (FR-213). Moves and copies refuse an existing destination; writes refuse an
existing file without `overwrite` (FR-214). Each change returns an `activity`, which posts the
notification and goes in the trace (FR-208).

Latchkey's own files (FR-210): before any change, the path is compared with a short list: the
app's folder in Application Support (the activity log), files named `net.melisma.latchkey.*`
in `~/Library/Preferences` and `~/Library/Preferences/ByHost` (the settings, which hold the
capability levels: a write there could turn a capability on at the next launch), and the
running app's bundle (which also holds the keep-awake helper and its launchd file; the login
item and the helper's registration are kept by macOS, not in files the Owner can write). Write,
append, edit, and create folder are refused inside them; so is the destination of a move or
copy; a move's source and the Trash are refused inside them and also for a folder that holds
one of them (trashing `~/Library` would take them along). The comparison follows symbolic
links, also on the way to a file that doesn't exist yet, and ignores letter case and accent
encoding, as the Mac's disk does. The error is "Latchkey doesn't change its own files. Nothing
was changed." Reading, and copying one of them elsewhere, stay allowed. No other path is
restricted. Shell, when on, can still change these files: it runs any command by design.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/FilesTests.swift`
- `macos/Tests/OwnFilesTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
