# 0177. Evals in the same sandbox (FR-1608)

- Status: accepted
- Date: 2026-11-25
- Alias: plan 016 D4 (`specs/016-test-strategy/plan.md`, "D4. Evals in the same sandbox (FR-1608)")

## Context and problem

Decision D4 of spec 016's plan (Test strategy and two ways to work); requirements in
[requirements/test-strategy.md](../requirements/test-strategy.md). Requirement IDs it cites: FR-1608.
The design it belongs to: [design/test-strategy.md](../design/test-strategy.md).

## Decision


- `make evals` = weekly-eval.sh renamed, on the sandbox of D3, with the local build or
  `--release`; 20 tasks × 3, scored on the end state, pass^3 per task, compared with the last
  run (`latchkey-reports evals`). Run by a local session when a tool, its description or its
  answers change, and on a new Claude model; reported, never a gate.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
