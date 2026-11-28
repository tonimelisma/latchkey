# 0165. One program, `relay/cmd/e2e` (FR-1500 to FR-1506, FR-1515 to FR-1526)

- Status: accepted
- Date: 2026-11-24
- Alias: plan 015 D1 (`specs/015-e2e-evals/plan.md`, "D1. One program, `relay/cmd/e2e` (FR-1500 to FR-1506, FR-1515 to FR-1526)")

## Context and problem

Decision D1 of spec 015's plan (End-to-end tests and evals); requirements in
[requirements/e2e-evals.md](../requirements/e2e-evals.md). Requirement IDs it cites: FR-1500, FR-1506, FR-1515, FR-1526.
The design it belongs to: [design/e2e-evals.md](../design/e2e-evals.md).

## Decision

Subcommands: `pick` (paths to capabilities), `checks` (the deterministic end-to-end checks),
`snap` (tool snapshots), `weekly` (checks plus Claude tasks, inside the test Mac), `fixture`
(set up, check and clean test data on macOS). It reuses what the existing checks have: the
private relay start-up and headless-Chrome sign-up (`relay/internal/e2e`), the Go MCP client,
Claude Code non-interactive (`relay/internal/e2e/claude.go`, extended to read stream-json). The
existing `localcheck`, `linuxcheck`, `maccheck` stay as they are (until spec 016 D2 removed
`localcheck` and `maccheck`, 2026-11-26); their shared start-up moves
into `relay/internal/e2e` where it isn't already (Constitution VIII: one new program, no
second harness).

## Confirmation

The tests that validate the requirements it cites:

- `relay/internal/evals/evals_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
