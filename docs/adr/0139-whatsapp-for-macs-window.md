# 0139. WhatsApp for Mac's window (withdrawn 2026-11-04)

- Status: withdrawn (the decision text says why; kept as the record)
- Date: 2026-11-04
- Alias: plan 012 D3 (`specs/012-whatsapp/plan.md`, "D3. WhatsApp for Mac's window (withdrawn 2026-11-04)")

## Context and problem

Decision D3 of spec 012's plan (WhatsApp); requirements in
[requirements/whatsapp.md](../requirements/whatsapp.md). Requirement IDs it cites: none current.
The design it belongs to: [design/whatsapp.md](../design/whatsapp.md).

## Decision


Withdrawn the same day it was built and checked live (maintainer's decision): it works only with the Mac unlocked,
which is when it is least needed. What it did, for the record:

- Used only when the Safari tab is unusable before anything was sent (FR-1216), the Mac is
  unlocked, and the message is text to a person (a number, or a chat in the database whose id is
  `<digits>@s.whatsapp.net`); otherwise the answer says why nothing was sent.
- WhatsApp for Mac can't be scripted (no AppleScript dictionary; research). Latchkey opens
  `whatsapp://send?phone=<digits>&text=<text>`, which opens the chat with the text in the box,
  waits for WhatsApp to be in front with that text in its focused field (Accessibility, as the
  computer tools use), presses Return in WhatsApp alone (a key event posted to its process), and
  brings back the app that was in front.
- Confirmation: the message in WhatsApp for Mac's database, from the Owner, with that text, within
  15 s; otherwise the answer says it may have gone (never retried).

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
