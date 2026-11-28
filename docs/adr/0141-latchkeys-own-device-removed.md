# 0141. Latchkey's own device, removed

- Status: withdrawn (the decision text says why; kept as the record)
- Date: 2026-11-04
- Alias: plan 012 D4 (`specs/012-whatsapp/plan.md`, "D4. Latchkey's own device, removed")

## Context and problem

Decision D4 of spec 012's plan (WhatsApp); requirements in
[requirements/whatsapp.md](../requirements/whatsapp.md). Requirement IDs it cites: FR-1206, FR-1207.
The design it belongs to: [design/whatsapp.md](../design/whatsapp.md).

## Decision


Serves FR-1206, FR-1207.

- No hidden page, no `whatsapp_link`, no linking window, no Settings link row. The bridge has no
  log-in or log-out functions.
- At the first start of this version (once, recorded in Latchkey's settings), Latchkey deletes the
  website data store of its old device (fixed identifier `6F1C2A4E-…`) and the `whatsappLinked`
  flag. WebKit must be set up first (a web view made) or deleting a store crashes (0.8.101).

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
