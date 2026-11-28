# 0157. The setting (FR-1400 to FR-1403)

- Status: accepted
- Date: 2026-11-23
- Alias: plan 014 D1 (`specs/014-feedback-intake/plan.md`, "D1. The setting (FR-1400 to FR-1403)")

## Context and problem

Decision D1 of spec 014's plan (Problem reports to the developer); requirements in
[requirements/feedback-intake.md](../requirements/feedback-intake.md). Requirement IDs it cites: FR-1400, FR-1403, FR-1402, FR-1415a.
The design it belongs to: [design/feedback-intake.md](../design/feedback-intake.md).

## Decision


The Mac app's Settings gets "Share problem reports with Latchkey's developer" beside the
capabilities, Off by default, with the explanation of FR-1402 shown before it takes effect. The
app sends the account's choice to the relay in its state message (a new field, contract
`docs/design/contracts/feedback-intake.md`), and the relay keeps one flag per account. A relay whose operator
added the block (FR-1415a) says so in its welcome, and the app says this relay doesn't forward
problem reports.

## Confirmation

The tests that validate the requirements it cites:

- `relay/internal/mcpserver/feedback_test.go`
- `relay/internal/store/reports_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
