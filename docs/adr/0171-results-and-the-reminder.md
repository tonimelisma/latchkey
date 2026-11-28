# 0171. Results and the reminder (FR-1511, FR-1530 to FR-1533)

- Status: accepted
- Date: 2026-11-24
- Alias: plan 015 D7 (`specs/015-e2e-evals/plan.md`, "D7. Results and the reminder (FR-1511, FR-1530 to FR-1533)")

## Context and problem

Decision D7 of spec 015's plan (End-to-end tests and evals); requirements in
[requirements/e2e-evals.md](../requirements/e2e-evals.md). Requirement IDs it cites: FR-1530, FR-1533, FR-1530a, FR-1532.
The design it belongs to: [design/e2e-evals.md](../design/e2e-evals.md).

## Decision

Every run writes `e2e-results/<run>.json` in the clone (FR-1530, FR-1530a): a developer's agent
in that clone reads it directly. With `--send`, the same result is sealed and sent as
`docs/design/contracts/eval-result.md` says, through the intake's existing endpoint (no intake change).
`latchkey-reports` gains `evals` (list sent results, joined by run, compared with the previous
run: new failures, fixed, flaky) and `list` keeps showing only problem reports. The weekly reminder
(`evals -this-week -quiet`) was removed on 2026-11-25 with FR-1511 (decided: "Drop it, keep per-PR
checks"): there is no weekly run; a session reads sent results with `evals` when there are any.
The session tells the maintainer that line. Each new failure becomes an issue found (FR-1532); sent results
are deleted once dispositioned (FR-1533).

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
