# 0080. Visibility (FR-507)

- Status: accepted
- Date: 2026-10-22
- Alias: plan 006 D6 (`specs/006-computer-control/plan.md`, "D6. Visibility (FR-507)")

## Context and problem

Decision D6 of spec 006's plan (Computer control); requirements in
[requirements/computer-control.md](../requirements/computer-control.md). Requirement IDs it cites: FR-507.
The design it belongs to: [design/computer-control.md](../design/computer-control.md).

## Decision


Every action returns an activity; the first after 5 minutes idle also posts the notification
"Claude is using your screen".

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
