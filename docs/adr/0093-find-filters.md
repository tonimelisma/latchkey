# 0093. Find filters (FR-801, SC-801)

- Status: accepted
- Date: 2026-10-29
- Alias: plan 008 D3 (`specs/008-mail/plan.md`, "D3. Find filters (FR-801, SC-801)")

## Context and problem

Decision D3 of spec 008's plan (Mail); requirements in
[requirements/mail.md](../requirements/mail.md). Requirement IDs it cites: none current.
The design it belongs to: [design/mail.md](../design/mail.md).

## Decision


SQL over `messages`, `subjects`, `addresses`, `recipients`, `mailboxes`, `labels`,
`attachments`, `deleted = 0`, `ORDER BY date_received DESC`, `LIMIT`/`OFFSET`: `from` (sender
address or name, `LIKE`), `to` (any recipient), `subject`, `account` (name, address, or id),
`mailbox` (name, e.g. "Inbox", in every account unless `account` is given; matches the last part
of the mailbox's path, so "Inbox" finds Gmail's `INBOX` label and Exchange's `Inbox`), `since`,
`until`, `unread`, `flagged`, `has_attachments`. Default 25 results, at most 100; the answer says
how to get the next page. Research measured 0.02–0.4 s for such queries over 100,000 messages.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
