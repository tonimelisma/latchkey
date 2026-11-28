# 0024. A lost permission is told to the Owner (FR-626)

- Status: accepted
- Date: 2026-10-31
- Alias: plan 001 D23 (`specs/001-core/plan.md`, "D23. A lost permission is told to the Owner (FR-626)")

## Context and problem

Decision D23 of spec 001's plan (Core: connect Claude to the Mac); requirements in
[requirements/core.md](../requirements/core.md). Requirement IDs it cites: FR-626, FR-621.
The design it belongs to: [design/core.md](../design/core.md).

## Decision


- Every minute the app runs `checkApprovals` (the same look the Settings and Setup windows run
  every second) and compares the Permissions tab's list with the last look
  (`PermissionLoss`): an id allowed then and missing now is a loss. "Checking…" is neither, and
  what was missing from the start is setup's (FR-621). Local Network's check sends a probe and
  takes up to 2 seconds, so it is forced only every tenth minute; a failed Shell call looks
  sooner. A failed call of any tool triggers the same look, so a loss is told as it is felt.
- One notification per look, category `permissionLost`; the app delegate, now the
  notification centre's delegate, opens setup on a click on that category only. Other notices
  are unchanged.
- Options for telling: (a) a notification, chosen: it waits in Notification Center while the
  Mac is unattended; (b) opening the setup window at once, which would pop up in front of
  whatever the Owner is doing, or over an empty desk; (c) only the menu bar mark, easy to miss.
  The mark comes with (a) anyway.
- Options for looking: (a) every minute, chosen: the checks are cheap (no prompt, no app
  opened); (b) macOS's notifications about privacy changes, which don't exist for most of
  these permissions; (c) only when a call fails, which misses losses while Claude isn't used.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/PermissionLossTests.swift`
- `macos/Tests/SetupDecisionTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
