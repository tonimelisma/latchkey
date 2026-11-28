# 0019. Diagnostic log in macOS's unified log

- Status: accepted
- Date: 2026-10-27
- Alias: plan 001 D16 (`specs/001-core/plan.md`, "D16. Diagnostic log in macOS's unified log")

## Context and problem

Decision D16 of spec 001's plan (Core: connect Claude to the Mac); requirements in
[requirements/core.md](../requirements/core.md). Requirement IDs it cites: FR-620, FR-633.
The design it belongs to: [design/core.md](../design/core.md).

## Decision

Serves FR-620; Constitution VI (nothing new stored by Latchkey: macOS keeps and ages its own
log). `Shared/Diagnostics.swift` holds one `Logger` per category under the app's subsystem:
`keepawake`, `helper`, `connection`, `power`, `permissions` (the existing `lifecycle` and
`activity` stay). States checked every few seconds pass through `Changes`, which lets a line
through only when it differs from the last. Interpolated values are private by default; only
fixed states, error descriptions, close codes and reasons, and app bundle IDs are `.public`.
Read with `log show --predicate 'subsystem == "net.melisma.latchkey"'`. Options considered: a
file of our own (rejected: another store to protect and age), the activity log (rejected: it
records Claude's actions, and these are the app's own). Changed 2026-10-27 (FR-633): macOS
discarded these lines within hours, so each one is now also an event in the activity log (D19);
the lines in macOS's log stay, with an `audit` category added.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/AuditTrailTests.swift`
- `macos/Tests/DiagnosticsTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
