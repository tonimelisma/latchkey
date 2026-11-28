# 0159. Filing on the relay (FR-1410 to FR-1416)

- Status: accepted
- Date: 2026-11-23
- Alias: plan 014 D3 (`specs/014-feedback-intake/plan.md`, "D3. Filing on the relay (FR-1410 to FR-1416)")

## Context and problem

Decision D3 of spec 014's plan (Problem reports to the developer); requirements in
[requirements/feedback-intake.md](../requirements/feedback-intake.md). Requirement IDs it cites: FR-1410, FR-1416, FR-1411, FR-1410a, FR-1412, FR-1415, FR-1415a.
The design it belongs to: [design/feedback-intake.md](../design/feedback-intake.md).

## Decision


`feedback` is answered by the relay as before, its description saying what must stay out of a
report (FR-1411) and asking Claude to name every machine involved in its `machines` argument
(FR-1410a; the older single `machine` is still accepted from chats that started before). The
machines part (`reportMachines`) matches the names to the account's machines, case-insensitively,
and gives each one's kind, versions and screen state, never its name; with no name that matches,
every online machine (FR-1412, report format 2, 2026-11-24). It builds the report of FR-1412 from what Claude wrote, unchanged, seals it
with `crypto/hpke` to the configured developer key (package `relay/reports`), and stores only the
sealed bytes in the `report_outbox` table. A sender goroutine finds each report's proof of work
for the current hour, posts it to the intake with backoff, deletes it on acceptance or a lasting
refusal, and deletes it after 7 days with a log line. Before each send it checks again that the
account still shares (security review 2026-11-23), so a report filed just before sharing went
off, or for a machine since removed, never leaves. The relay's old report table and the delivery
to the Mac (spec 001 FR-691 to FR-693, withdrawn) are removed; migration 00015 drops the old rows.

Operator settings (environment): `REPORTS_INTAKE_URL` and `REPORTS_DEVELOPER_KEY` (base64 public
key), both defaulting to Latchkey's developer (`relay/reports/defaults.go`, FR-1415);
`REPORTS_BLOCK=1` adds the operator's block (FR-1415a).

## Confirmation

The tests that validate the requirements it cites:

- `relay/internal/mcpserver/feedback_internal_test.go`
- `relay/internal/mcpserver/feedback_test.go`
- `relay/internal/store/reports_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
