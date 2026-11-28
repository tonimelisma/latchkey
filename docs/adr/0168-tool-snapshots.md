# 0168. Tool snapshots (FR-1504)

- Status: accepted
- Date: 2026-11-24
- Alias: plan 015 D4 (`specs/015-e2e-evals/plan.md`, "D4. Tool snapshots (FR-1504)")

## Context and problem

Decision D4 of spec 015's plan (End-to-end tests and evals); requirements in
[requirements/e2e-evals.md](../requirements/e2e-evals.md). Requirement IDs it cites: none current.
The design it belongs to: [design/e2e-evals.md](../design/e2e-evals.md).

## Decision

`relay/e2e/toolsnaps/<relay|mac|linux>/<tool>.json`: name, description, input schema, as a real
MCP client lists them through the relay with every capability on. `e2e snap` compares; with
`-update` it rewrites. The Mac's snapshots can only be listed on macOS, so `e2e-mac` uploads
the new snapshots as a workflow artifact when they differ and prints the diff; a cloud session
downloads them and commits them in the same pull request. This also makes the rule "a tool
whose behavior changes gets a new name" (`.claude/rules/tool-design.md`) visible in review.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
