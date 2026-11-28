# 0058. Jobs in every answer (FR-322)

- Status: accepted
- Date: 2026-10-27
- Alias: plan 004 D12 (`specs/004-shell/plan.md`, "D12. Jobs in every answer (FR-322)")

## Context and problem

Decision D12 of spec 004's plan (Shell); requirements in
[requirements/shell.md](../requirements/shell.md). Requirement IDs it cites: FR-322.
The design it belongs to: [design/shell.md](../design/shell.md).

## Decision


The app appends a text line to every tool result while any job runs or is kept:
`[Shell: job3 running since 14:05; job2's leftovers kept until 15:40 (check job2 to keep them)]`.
It is part of the Mac's result (the relay's state line follows it), so no protocol change.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
