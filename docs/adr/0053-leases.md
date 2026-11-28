# 0053. Leases (FR-314)

- Status: accepted
- Date: 2026-10-27
- Alias: plan 004 D7 (`specs/004-shell/plan.md`, "D7. Leases (FR-314)")

## Context and problem

Decision D7 of spec 004's plan (Shell); requirements in
[requirements/shell.md](../requirements/shell.md). Requirement IDs it cites: FR-314.
The design it belongs to: [design/shell.md](../design/shell.md).

## Decision


`shell_run` takes `keep_minutes` (0 to 1440, default 0). A job's lease ends `keep_minutes` after
the command finished; `shell_check` of the job starts the time again; the end never passes 24
hours after the command finished. A timer every minute ends the leases that are due. A job with
a lease running stays listed past the usual 10 minutes.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
