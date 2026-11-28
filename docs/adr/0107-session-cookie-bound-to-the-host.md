# 0107. Session cookie bound to the host (FR-912)

- Status: accepted
- Date: 2026-10-31
- Alias: plan 009 D5 (`specs/009-easy-relay-setup/plan.md`, "D5. Session cookie bound to the host (FR-912)")

## Context and problem

Decision D5 of spec 009's plan (Easy relay setup); requirements in
[requirements/easy-relay-setup.md](../requirements/easy-relay-setup.md). Requirement IDs it cites: FR-912.
The design it belongs to: [design/easy-relay-setup.md](../design/easy-relay-setup.md).

## Decision


- Already the case (found while building, 2026-10-31): on HTTPS the session cookie is named
  `__Host-latchkey_session` (Path `/`, no Domain, Secure), so no other site under a shared parent
  name (sslip.io) can set or read it; over plain HTTP (local development) it is
  `latchkey_session`. Nothing to change, and no one is signed out.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
