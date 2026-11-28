# 0051. Levels and visibility

- Status: accepted
- Date: 2026-10-22
- Alias: plan 004 D5 (`specs/004-shell/plan.md`, "D5. Levels and visibility")

## Context and problem

Decision D5 of spec 004's plan (Shell); requirements in
[requirements/shell.md](../requirements/shell.md). Requirement IDs it cites: FR-308, FR-307.
The design it belongs to: [design/shell.md](../design/shell.md).

## Decision


Capabilities gain a list of the levels they offer: shell offers Off and On (On = full use),
starting On (FR-308). `shell_run` returns an `activity` ("Claude ran: …") for the notification
and the trace (FR-307).

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
