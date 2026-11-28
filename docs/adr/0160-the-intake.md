# 0160. The intake (FR-1420 to FR-1425)

- Status: accepted
- Date: 2026-11-23
- Alias: plan 014 D4 (`specs/014-feedback-intake/plan.md`, "D4. The intake (FR-1420 to FR-1425)")

## Context and problem

Decision D4 of spec 014's plan (Problem reports to the developer); requirements in
[requirements/feedback-intake.md](../requirements/feedback-intake.md). Requirement IDs it cites: FR-1420, FR-1425, FR-1424.
The design it belongs to: [design/feedback-intake.md](../design/feedback-intake.md).

## Decision


A Go program in the relay's module (`relay/cmd/latchkey-intake`, `relay/internal/intake`;
`docs/research/2026-11-23-feedback-intake.md`, "repository layout"), SQLite, one container (`relay/Dockerfile.intake`), with the
relay's lint, security checks and tests, published and signed by `relay-image.yml` as
`ghcr.io/tonimelisma/latchkey-intake`:

- `POST /v1/reports`: body = sealed report; headers carry the proof-of-work nonce and hour.
  Refuses bodies over 64 KB, a bad proof, a body without the report's shape (the `LKR1` mark and
  at least the HPKE encapsulation and tag), a sender over its hourly limit, or more than 10,000
  waiting reports. Answers 202 with the report's id.
- `GET /v1/reports`, `GET /v1/reports/{id}`, `DELETE /v1/reports/{id}`: only with the
  developer's token (bearer); sealed bytes out. The agent deletes a report once it is
  dispositioned (FR-1424): the fix, its regression case, or the reason in the agent's reply is the
  record, nothing stays in the intake.

## Confirmation

The tests that validate the requirements it cites:

- `relay/internal/intake/intake_test.go`
- `relay/reports/reports_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
