# 0158. Asking Claude (FR-1401, FR-1405, FR-1406)

- Status: accepted
- Date: 2026-11-23
- Alias: plan 014 D2 (`specs/014-feedback-intake/plan.md`, "D2. Asking Claude (FR-1401, FR-1405, FR-1406)")

## Context and problem

Decision D2 of spec 014's plan (Problem reports to the developer); requirements in
[requirements/feedback-intake.md](../requirements/feedback-intake.md). Requirement IDs it cites: FR-1401, FR-1405, FR-1406.
The design it belongs to: [design/feedback-intake.md](../design/feedback-intake.md).

## Decision


The relay builds its tool list and server instructions per account: with the flag off,
`feedback` and every mention of it are left out (the general instructions no longer mention it
at all; the tool's description carries the guidance, FR-1405). With it on, the relay appends one
line to every error answer it passes to Claude (the relay sees every answer, so no Mac change is
needed). A machine whose `share_reports` changes makes the relay re-sync the tool list.

## Confirmation

The tests that validate the requirements it cites:

- `relay/internal/mcpserver/feedback_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
