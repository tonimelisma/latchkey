# 0047. Tools (level On)

- Status: accepted
- Date: 2026-10-22
- Alias: plan 004 D1 (`specs/004-shell/plan.md`, "D1. Tools (level On)")

## Context and problem

Decision D1 of spec 004's plan (Shell); requirements in
[requirements/shell.md](../requirements/shell.md). Requirement IDs it cites: FR-301, FR-302, FR-307, FR-314, FR-318, FR-303.
The design it belongs to: [design/shell.md](../design/shell.md).

## Decision


Claude sees consolidated tools (decided 2026-10-23: 15 tools in all, from 45): the table below. The operations listed after it are their internals, each reached by an `action` or by which arguments are given.

| Tool | readOnly | destructive | Operations behind it |
|---|---|---|---|
| `shell_run` (command, folder?, wait?, writes?, why?, keep_minutes?; or job + input / stop) | no | yes | run, send, stop |
| `shell_check` (job?, wait?) | yes | no | check; without job, list jobs |

Operations:

| Tool | readOnly | destructive | Serves |
|---|---|---|---|
| `shell_run` (command, folder?, wait?, writes?, why?, keep_minutes?) | no | yes | FR-301, FR-302, FR-307, FR-314, FR-318 |
| `shell_check` (job, wait?) | yes | no | FR-303 |
| `shell_send` (job, text, enter?) | no | yes | FR-303 |
| `shell_stop` (job) | no | yes | FR-303 |
| `shell_jobs` | yes | no | FR-303 |

`shell_run` and `shell_send` declare `openWorldHint` (commands reach the network). Deadline 45 s
(30 s wait plus margin; Claude allows 240 s).

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
