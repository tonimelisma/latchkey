# 0075. Tools

- Status: accepted
- Date: 2026-10-22
- Alias: plan 006 D1 (`specs/006-computer-control/plan.md`, "D1. Tools")

## Context and problem

Decision D1 of spec 006's plan (Computer control); requirements in
[requirements/computer-control.md](../requirements/computer-control.md). Requirement IDs it cites: FR-501, FR-503, FR-502, FR-509.
The design it belongs to: [design/computer-control.md](../design/computer-control.md).

## Decision


Claude sees consolidated tools (decided 2026-10-23: 15 tools in all, from 45): the table below. The operations listed after it are their internals, each reached by an `action` or by which arguments are given.

| Tool | Level | readOnly | destructive | Operations behind it |
|---|---|---|---|---|
| `computer_look` (show: screenshot, ui, apps; display?) | Read only | yes | no | screenshot, front window, apps |
| `computer_act` (action: click, move, drag, scroll, type, key, open_app; …) | Read & write | no | yes | the matching action |

Operations:

| Tool | Level | readOnly | destructive | Serves |
|---|---|---|---|---|
| `computer_screenshot` (display?) | Read only | yes | no | FR-501, FR-503 |
| `computer_ui` | Read only | yes | no | FR-501 |
| `computer_apps` | Read only | yes | no | FR-501 |
| `computer_click` (x, y, button?, count?) | Read & write | no | yes | FR-502 |
| `computer_move` (x, y) | Read & write | no | no | FR-502 |
| `computer_drag` (from_x, from_y, to_x, to_y) | Read & write | no | yes | FR-502 |
| `computer_scroll` (x, y, direction, amount?) | Read & write | no | no | FR-502 |
| `computer_type` (text) | Read & write | no | yes | FR-502 |
| `computer_key` (keys) | Read & write | no | yes | FR-502 |
| `computer_open_app` (name) | Read & write | no | no | FR-502 |
| `browser_screenshot` | Browser Read only | yes | no | FR-509 |

Actions answer with a new screenshot taken 0.5 s later, so Claude sees the effect without a
second call. Deadline 20 s.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
