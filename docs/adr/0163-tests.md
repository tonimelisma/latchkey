# 0163. Tests

- Status: accepted
- Date: 2026-11-23
- Alias: plan 014 D6 (`specs/014-feedback-intake/plan.md`, "D6. Tests")

## Context and problem

Decision D6 of spec 014's plan (Problem reports to the developer); requirements in
[requirements/feedback-intake.md](../requirements/feedback-intake.md). Requirement IDs it cites: none current.
The design it belongs to: [design/feedback-intake.md](../design/feedback-intake.md).

## Decision


- Relay: tool absent and no line with the flag off; the description names what stays out; the outbox never holds
  plaintext (the database is searched for the report's words); retry, acceptance, and the 7-day
  drop; turning sharing off drops waiting reports.
- Intake: refuses big, unproven, malformed, and over-limit bodies; the developer endpoints need
  the token; nothing it stores opens without the key.
- End to end in tests: a relay and an intake in one process, a report filed through a real MCP
  client, opened with the test key.
- Mac: the setting and its explanation; the state message carries it.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
