# 0079. Permissions and setup (FR-506)

- Status: accepted
- Date: 2026-10-22
- Alias: plan 006 D5 (`specs/006-computer-control/plan.md`, "D5. Permissions and setup (FR-506)")

## Context and problem

Decision D5 of spec 006's plan (Computer control); requirements in
[requirements/computer-control.md](../requirements/computer-control.md). Requirement IDs it cites: FR-506.
The design it belongs to: [design/computer-control.md](../design/computer-control.md).

## Decision


Two setup steps while Computer control isn't Off: Screen Recording (`CGRequestScreenCaptureAccess`,
then System Settings → Screen & System Audio Recording) and Accessibility
(`AXIsProcessTrustedWithOptions` with the prompt, then System Settings → Accessibility). The
window notices both. Tools explain a missing one.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
