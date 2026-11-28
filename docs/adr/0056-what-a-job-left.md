# 0056. What a job left (FR-321, FR-323)

- Status: accepted
- Date: 2026-10-27
- Alias: plan 004 D10 (`specs/004-shell/plan.md`, "D10. What a job left (FR-321, FR-323)")

## Context and problem

Decision D10 of spec 004's plan (Shell); requirements in
[requirements/shell.md](../requirements/shell.md). Requirement IDs it cites: FR-321, FR-323, FR-620.
The design it belongs to: [design/shell.md](../design/shell.md).

## Decision


When the leftovers are swept, the answer that reports the end (or the next one) and the activity
log get one Left Behind entry: the processes stopped (by name), the scratch folder moved to the
Trash or kept until when, and the files new or changed since the job started in the declared
paths and in Downloads (at most 20 named, then a count; at most 2,000 entries looked at), each
declared permanent place marked "permanent change". The entry goes to the activity log only
(`EventLog`, `systemLog: false`: it names files, which macOS's log must not, spec 001 FR-620).

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/DiagnosticsTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
