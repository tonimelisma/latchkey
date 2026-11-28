# 0127. Full traces in daily files (FR-1057 to FR-1059; decided 2026-11-15)

- Status: accepted
- Date: 2026-11-15
- Alias: plan 010 D16 (`specs/010-multi-host/plan.md`, "D16. Full traces in daily files (FR-1057 to FR-1059; decided 2026-11-15)")

## Context and problem

Decision D16 of spec 010's plan (Several machines and Linux servers); requirements in
[requirements/multi-host.md](../requirements/multi-host.md). Requirement IDs it cites: FR-1057, FR-1059.
The design it belongs to: [design/multi-host.md](../design/multi-host.md).

## Decision


The activity log moves from one file with cut arguments and results to `activity/YYYY-MM-DD.jsonl`
in full (spec 001 plan D28, `contracts/trace-files.md`). The old `activity.jsonl` is read as
version 0 by everything that reads the log and never written again. `latchkey activity export`
writes the export line every side shares, so a server's trace joins the relay's by call id.

## Confirmation

The tests that validate the requirements it cites:

- `linux/internal/activity/activity_test.go`
- `linux/internal/activity/export_test.go`
- `linux/internal/agent/log_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
