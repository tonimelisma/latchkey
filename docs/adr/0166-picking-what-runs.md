# 0166. Picking what runs (FR-1500, FR-1502, FR-1504)

- Status: accepted
- Date: 2026-11-24
- Alias: plan 015 D2 (`specs/015-e2e-evals/plan.md`, "D2. Picking what runs (FR-1500, FR-1502, FR-1504)")

## Context and problem

Decision D2 of spec 015's plan (End-to-end tests and evals); requirements in
[requirements/e2e-evals.md](../requirements/e2e-evals.md). Requirement IDs it cites: FR-1500, FR-1502.
The design it belongs to: [design/e2e-evals.md](../design/e2e-evals.md).

## Decision

`relay/e2e/capabilities.json` maps path globs to capabilities and each capability to its
checks; shared paths (`relay/internal/server`, `relay/agentproto`, `macos/App/AgentProtocol.swift`,
`macos/App/AppModel.swift`, the workflow and `relay/cmd/e2e` themselves, …) select all. A
changed tool snapshot selects its capability. `e2e pick` reads `git diff --name-only` against
the pull request's base and prints the selection; a test fails when a source file under
`macos/App/`, `linux/` or `relay/internal/` matches no glob, so new code can't fall outside the
map.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
