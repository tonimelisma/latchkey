# 0173. Releases and the requester's conditions (FR-1540, FR-1541)

- Status: accepted
- Date: 2026-11-24
- Alias: plan 015 D9 (`specs/015-e2e-evals/plan.md`, "D9. Releases and the requester's conditions (FR-1540, FR-1541)")

## Context and problem

Decision D9 of spec 015's plan (End-to-end tests and evals); requirements in
[requirements/e2e-evals.md](../requirements/e2e-evals.md). Requirement IDs it cites: FR-1540, FR-1541.
The design it belongs to: [design/e2e-evals.md](../design/e2e-evals.md).

## Decision

No release workflow changes: a merged commit is "checked" when its pull request's end-to-end
checks passed (FR-1540). `docs/STATUS.md` gets a "Weekly run" line (date, release, passes, new failures).
CLAUDE.md, "Done means the requester's conditions", gains one sentence: a weekly result is evidence only
for a condition the test Mac really has (unlocked, Latchkey's own browser, a local page, test
data), quoted with version and time; locked, lid closed, real iMessage, real sites and the maintainer's
accounts stay NOT VERIFIED until the maintainer runs them.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
