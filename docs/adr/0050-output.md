# 0050. Output

- Status: accepted
- Date: 2026-10-22
- Alias: plan 004 D4 (`specs/004-shell/plan.md`, "D4. Output")

## Context and problem

Decision D4 of spec 004's plan (Shell); requirements in
[requirements/shell.md](../requirements/shell.md). Requirement IDs it cites: FR-304, FR-305.
The design it belongs to: [design/shell.md](../design/shell.md).

## Decision


Control sequences removed; carriage-return redraws keep the last version of the line; at most
50,000 characters per answer, the most recent, saying how much was left out (FR-304, FR-305).

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
