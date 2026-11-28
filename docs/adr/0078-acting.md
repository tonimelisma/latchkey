# 0078. Acting

- Status: accepted
- Date: 2026-10-22
- Alias: plan 006 D4 (`specs/006-computer-control/plan.md`, "D4. Acting")

## Context and problem

Decision D4 of spec 006's plan (Computer control); requirements in
[requirements/computer-control.md](../requirements/computer-control.md). Requirement IDs it cites: none current.
The design it belongs to: [design/computer-control.md](../design/computer-control.md).

## Decision


Quartz events through a small poster interface (a fake in tests): mouse move, down/up with the
click count, right button, drag in 10 steps, scroll in lines, Unicode text in chunks, key
combinations by name (`cmd+shift+4`). Points are screenshot pixels mapped to the display's
global coordinates. Opening apps uses NSWorkspace by name.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
