# 0132. Versions (FR-1111)

- Status: withdrawn with spec 011, 2026-11-01 (kept as the record)
- Date: 2026-11-01
- Alias: plan 011 D5 (`specs/011-claude-plugin/plan.md`, "D5. Versions (FR-1111)")

## Context and problem

Decision D5 of spec 011's plan (The Claude plugin (withdrawn)); requirements in
[requirements/claude-plugin.md](../requirements/claude-plugin.md). Requirement IDs it cites: none current.
The design it belongs to: [design/claude-plugin.md](../design/claude-plugin.md).

## Decision


`version` in `plugin.json` only (not in the catalog entry), starting at 0.1.0, raised with every
change to `plugin/` the way the Mac app's version is. The content check compares `plugin/` with
`origin/main` and fails when it changed and the version didn't. Updates then reach claude.ai by
itself, and Claude Code where the catalog came from claude.ai or auto-update is on (research R3).

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
