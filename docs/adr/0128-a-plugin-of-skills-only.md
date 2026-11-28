# 0128. A plugin of skills only (FR-1101, FR-1102, FR-1106)

- Status: withdrawn with spec 011, 2026-11-01 (kept as the record)
- Date: 2026-11-01
- Alias: plan 011 D1 (`specs/011-claude-plugin/plan.md`, "D1. A plugin of skills only (FR-1101, FR-1102, FR-1106)")

## Context and problem

Decision D1 of spec 011's plan (The Claude plugin (withdrawn)); requirements in
[requirements/claude-plugin.md](../requirements/claude-plugin.md). Requirement IDs it cites: none current.
The design it belongs to: [design/claude-plugin.md](../design/claude-plugin.md).

## Decision


The plugin holds two skills and nothing else: no `.mcp.json`, hooks, agents, commands, `bin/`,
or per-user settings. Skills are the only part that loads on every app (research R1), and
without a connector of its own the plugin works with any relay; the person adds the connector
as today. A plugin that fills in the hosted relay's address comes with the directory listing
(FR-1114).

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
