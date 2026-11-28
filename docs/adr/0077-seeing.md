# 0077. Seeing

- Status: accepted
- Date: 2026-10-22
- Alias: plan 006 D3 (`specs/006-computer-control/plan.md`, "D3. Seeing")

## Context and problem

Decision D3 of spec 006's plan (Computer control); requirements in
[requirements/computer-control.md](../requirements/computer-control.md). Requirement IDs it cites: FR-503.
The design it belongs to: [design/computer-control.md](../design/computer-control.md).

## Decision


ScreenCaptureKit captures a display at a size whose longest side is at most 1,568 pixels; the
answer gives the image and its size. Each display's scale (screen points per image pixel) is
fixed by that rule, so coordinates mean the same with or without a fresh screenshot (FR-503).
`computer_ui` reads the front app's focused window through the Accessibility API (role, label,
value, position in screenshot pixels), at most 300 elements, 15 levels deep. The front app
reports its own frames: one that isn't a point and size, or whose position is NaN, infinite, or
far off any screen, is listed with "no position" instead of crashing the conversion (security
scan, 2026-10-24).

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
