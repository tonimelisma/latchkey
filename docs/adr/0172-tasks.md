# 0172. Tasks (FR-1520 to FR-1526)

- Status: accepted
- Date: 2026-11-24
- Alias: plan 015 D8 (`specs/015-e2e-evals/plan.md`, "D8. Tasks (FR-1520 to FR-1526)")

## Context and problem

Decision D8 of spec 015's plan (End-to-end tests and evals); requirements in
[requirements/e2e-evals.md](../requirements/e2e-evals.md). Requirement IDs it cites: FR-1520, FR-1526, FR-1524, FR-1525.
The design it belongs to: [design/e2e-evals.md](../design/e2e-evals.md).

## Decision

About 20 tasks in `relay/e2e/tasks/` (format: `docs/design/contracts/task-format.md`), spread over the
capabilities the test Mac has: files, shell, Latchkey's own browser on local pages (sign-in,
download), Notes, Calendar, Reminders, Contacts, computer control on a test app; 3 or 4 with
planted instructions (a note, a page, a file) (FR-1524); 4 held out (FR-1526). Regression cases
from `cases.json` that need Claude or the test Mac are written as tasks, with `covers` (FR-1525;
since spec 016 retired `cases.json`, the cases are the rows of `docs/regression-coverage.md`).
Scoring: end state first, then forbidden calls, unneeded calls reported; no judge.

## Confirmation

The tests that validate the requirements it cites:

- `relay/cmd/e2e/fixture_test.go`
- `relay/internal/evals/evals_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
