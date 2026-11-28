# 0076. Screen state (FR-504, FR-505)

- Status: accepted
- Date: 2026-10-22
- Alias: plan 006 D2 (`specs/006-computer-control/plan.md`, "D2. Screen state (FR-504, FR-505)")

## Context and problem

Decision D2 of spec 006's plan (Computer control); requirements in
[requirements/computer-control.md](../requirements/computer-control.md). Requirement IDs it cites: FR-504, FR-505.
The design it belongs to: [design/computer-control.md](../design/computer-control.md).

## Decision


Before every tool: no active display → "no screen" (lid closed without a monitor); locked
(`CGSSessionScreenIsLocked`) → "locked"; display asleep → "asleep", left asleep (until
2026-11-02 it was woken with a user-activity assertion, which reset the idle time, so Claude's
looks could keep an idle Mac from locking; decided: never get around the idle lock). Each reason is a plain sentence
that also says files, shell, Notes, Messages, and the browser still work.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/ComputerTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
