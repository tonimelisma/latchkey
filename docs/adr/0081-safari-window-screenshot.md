# 0081. Safari window screenshot (FR-509)

- Status: accepted
- Date: 2026-10-22
- Alias: plan 006 D7 (`specs/006-computer-control/plan.md`, "D7. Safari window screenshot (FR-509)")

## Context and problem

Decision D7 of spec 006's plan (Computer control); requirements in
[requirements/computer-control.md](../requirements/computer-control.md). Requirement IDs it cites: FR-509.
The design it belongs to: [design/computer-control.md](../design/computer-control.md).

## Decision


ScreenCaptureKit finds Safari's window whose title is the title of Claude's current tab, and
captures it at the same size limit.
Since 2026-11-05, when the screen can't be captured (locked, display asleep, lid closed, no
permission) or the Owner can see the window, Latchkey draws the page instead (spec 005 plan
D10).

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
