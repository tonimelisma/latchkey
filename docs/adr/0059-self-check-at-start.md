# 0059. Self-check at start (FR-330, 2026-10-29)

- Status: accepted
- Date: 2026-10-29
- Alias: plan 004 D13 (`specs/004-shell/plan.md`, "D13. Self-check at start (FR-330, 2026-10-29)")

## Context and problem

Decision D13 of spec 004's plan (Shell); requirements in
[requirements/shell.md](../requirements/shell.md). Requirement IDs it cites: FR-330.
The design it belongs to: [design/shell.md](../design/shell.md).

## Decision


The fence (`sandbox-exec`, deprecated by Apple but working) and the mark (`sandbox_check`, no
public header) are macOS features an update could change without notice, which would leave
writes unfenced or double forks running without any error. At start, before what earlier runs
left is recovered, Latchkey runs `/bin/sh` under a profile that refuses one write and reading a
mark, in a folder `<launch>-check` in the Jobs folder: the write must fail and the program must
be found by its mark within 10 s (3 s failed once under load). The folder, mark, and program are removed at once. A failure
becomes a warning appended to every Shell answer and a Left Behind entry with one notification
(the maintainer chose to keep Shell running rather than refuse commands, 2026-10-29).

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/LeftoversTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
