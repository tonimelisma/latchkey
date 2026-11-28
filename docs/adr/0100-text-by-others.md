# 0100. Text by others (FR-806)

- Status: accepted
- Date: 2026-10-29
- Alias: plan 008 D9 (`specs/008-mail/plan.md`, "D9. Text by others (FR-806)")

## Context and problem

Decision D9 of spec 008's plan (Mail); requirements in
[requirements/mail.md](../requirements/mail.md). Requirement IDs it cites: none current.
The design it belongs to: [design/mail.md](../design/mail.md).

## Decision


Every result starts with the marking line Messages uses and puts every sender name, address,
subject, message text, and attachment name in «» (`MessagesCapability.quote`), so nothing inside
can pose as the end of the quote.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
