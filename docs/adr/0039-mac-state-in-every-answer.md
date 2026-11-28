# 0039. Mac state in every answer (spec 001 FR-065)

- Status: accepted
- Date: 2026-10-21
- Alias: plan 002 D7 (`specs/002-notes-messages/plan.md`, "D7. Mac state in every answer (spec 001 FR-065)")

## Context and problem

Decision D7 of spec 002's plan (Notes and Messages); requirements in
[requirements/notes-messages.md](../requirements/notes-messages.md). Requirement IDs it cites: FR-065, FR-200.
The design it belongs to: [design/notes-messages.md](../design/notes-messages.md).

## Decision


The relay appends one text block to every Mac tool result, built from the state it already
stores, for example `Mac: online · 64% battery, on battery · keep-awake on`. It adds a warning when
the battery is within 10 points of the sleep threshold or the Mac is too hot. `battery_status` and
`laptop_status` and the "System info" capability are removed (spec 001 FR-021, FR-063 withdrawn).
The block starts with a line break unless the result already ends with one, so the line is
always on its own line (spec 001 FR-200; rule in contracts/mcp-surface.md); the Mac's own blocks
are not changed.

## Confirmation

The tests that validate the requirements it cites:

- `relay/internal/mcpserver/mcpserver_test.go`
- `relay/internal/mcpserver/messages_test.go`
- `relay/internal/server/e2e_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
