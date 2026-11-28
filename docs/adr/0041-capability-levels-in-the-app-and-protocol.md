# 0041. Capability levels in the app and protocol

- Status: accepted
- Date: 2026-10-21
- Alias: plan 002 D9 (`specs/002-notes-messages/plan.md`, "D9. Capability levels in the app and protocol")

## Context and problem

Decision D9 of spec 002's plan (Notes and Messages); requirements in
[requirements/notes-messages.md](../requirements/notes-messages.md). Requirement IDs it cites: FR-120, FR-062.
The design it belongs to: [design/notes-messages.md](../design/notes-messages.md).

## Decision


Serves FR-120. Two capabilities, `notes` and `messages`, each with a level stored in user
defaults. The tool list the app sends (agent protocol `tools`) contains only the tools of each
capability's level; a level change sends a new list (FR-062). No protocol change is needed.

## Confirmation

The tests that validate the requirements it cites:

- `relay/internal/mcpserver/mcpserver_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
