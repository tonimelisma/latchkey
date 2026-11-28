# 0143. Deadline

- Status: accepted
- Date: 2026-11-03
- Alias: plan 012 D6 (`specs/012-whatsapp/plan.md`, "D6. Deadline")

## Context and problem

Decision D6 of spec 012's plan (WhatsApp); requirements in
[requirements/whatsapp.md](../requirements/whatsapp.md). Requirement IDs it cites: FR-011.
The design it belongs to: [design/whatsapp.md](../design/whatsapp.md).

## Decision


Serves FR-1212. `whatsapp_send` and `whatsapp_change` declare 60 s (spec 001 FR-011's cap): 5 s to look at the tab,
up to 25 s for a tab Latchkey opened to connect, and 25 s for the send (WhatsApp's confirmation
waited for up to 20 s).

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
