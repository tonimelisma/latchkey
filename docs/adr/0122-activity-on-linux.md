# 0122. Activity on Linux (FR-1050, FR-1051)

- Status: accepted
- Date: 2026-10-31
- Alias: plan 010 D11 (`specs/010-multi-host/plan.md`, "D11. Activity on Linux (FR-1050, FR-1051)")

## Context and problem

Decision D11 of spec 010's plan (Several machines and Linux servers); requirements in
[requirements/multi-host.md](../requirements/multi-host.md). Requirement IDs it cites: FR-1050, FR-1051.
The design it belongs to: [design/multi-host.md](../design/multi-host.md).

## Decision


Since 2026-11-15 (D16): `activity/YYYY-MM-DD.jsonl` (folder 0700, files 0600), one version-1
JSON line per call (the arguments as they came and the content array as sent to the relay, in
full) and per event, filed by the UTC day of its time, appended and synchronized per entry, with a
line break first when a crash left a line cut short. `activity.jsonl` of earlier versions (results
cut to 2,000 characters) is left as it is and read as version 0. `latchkey activity export
[--from] [--to]` writes the shared export line; its `machine` is the name the relay last welcomed
the server with, else the settings' name. `latchkey activity`
prints the last 50; `--check` prints the last audit comparison (agent-protocol "Audit
comparison"), which the service runs after each connection and logs. (A comparison of its own
would need a second connection, which would replace the service's.) No notifications.

## Confirmation

The tests that validate the requirements it cites:

- `linux/internal/activity/activity_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
