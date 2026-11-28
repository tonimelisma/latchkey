# 0054. Scratch folder (FR-315, FR-316)

- Status: accepted
- Date: 2026-10-27
- Alias: plan 004 D8 (`specs/004-shell/plan.md`, "D8. Scratch folder (FR-315, FR-316)")

## Context and problem

Decision D8 of spec 004's plan (Shell); requirements in
[requirements/shell.md](../requirements/shell.md). Requirement IDs it cites: FR-315, FR-316, FR-324.
The design it belongs to: [design/shell.md](../design/shell.md).

## Decision


`~/Library/Caches/<app data folder>/Jobs/<launch>-<job>/`, given to the command as `TMPDIR` and
`LATCHKEY_SCRATCH`, so `mktemp`, Python, Node, Go, and Chrome's temporary profiles land there.
Removing a job's leftovers moves the folder to the Trash (`FileManager.trashItem`), or deletes
it when empty. At start, folders of earlier launches are moved to the Trash too (FR-324).

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/LeftoversTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
