# 0098. Sending confirmed in Sent (FR-823, FR-824)

- Status: accepted
- Date: 2026-10-29
- Alias: plan 008 D7 (`specs/008-mail/plan.md`, "D7. Sending confirmed in Sent (FR-823, FR-824)")

## Context and problem

Decision D7 of spec 008's plan (Mail); requirements in
[requirements/mail.md](../requirements/mail.md). Requirement IDs it cites: none current.
The design it belongs to: [design/mail.md](../design/mail.md).

## Decision


- Before `send`, Latchkey notes the time. After it, it polls the database (every 0.5 s, up to
  30 s) for a message in that account's Sent mailbox (Mail's `sent mailbox` child for the
  account, its labels for Gmail) received since then, with the same subject and the first
  recipient, and takes its Message-ID from `message_global_data`. Mail's scripting can't set or
  read a Message-ID before sending, so the copy is identified this way, and the answer names the
  Message-ID. It then checks the copy has as many attachments as were sent.
- Found: "Sent … (Message-ID …)". Not found in time, or the script timed out: "Mail took the
  message but its copy isn't in Sent yet; don't send it again; check with mail_find mailbox Sent
  in a minute." Latchkey never sends again by itself (FR-823). No confirmations or limits of
  Latchkey's own (FR-824).

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
