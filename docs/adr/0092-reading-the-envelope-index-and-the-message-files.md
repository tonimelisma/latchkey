# 0092. Reading: the Envelope Index and the message files (FR-801, FR-803, FR-807, FR-831, FR-834)

- Status: accepted
- Date: 2026-10-29
- Alias: plan 008 D2 (`specs/008-mail/plan.md`, "D2. Reading: the Envelope Index and the message files (FR-801, FR-803, FR-807, FR-831, FR-834)")

## Context and problem

Decision D2 of spec 008's plan (Mail); requirements in
[requirements/mail.md](../requirements/mail.md). Requirement IDs it cites: none current.
The design it belongs to: [design/mail.md](../design/mail.md).

## Decision


- `~/Library/Mail/V<n>/MailData/Envelope Index`, the highest `V<n>` folder, opened with
  `SQLite.openReadOnly` (`mode=ro`, never `immutable`: that skips the WAL and misses new mail;
  research "Reading and searching"). Never written. Needs Full Disk Access, not Mail running.
- At open, `MailStore` checks the `properties` version (`4`) and every column it reads
  (`SELECT … LIMIT 0`); any difference is `unknownLayout`, answered plainly (FR-834), as the
  Messages and Notes stores do.
- A message's id for Claude is its `messages.ROWID`, which is also Mail's scripting `id` (checked
  live, research "Ids and paths"), so actions find the same message.
- Accounts: the account of a mailbox is the host part of its URL (`imap://<UUID>/INBOX`), which
  is Mail's scripting account id. Names and addresses come from Mail's scripting (`accounts`
  script) when Mail runs and Latchkey is already allowed to control it (asked with `ask:
  false`, so reading never shows a prompt); otherwise the account is named by its kind and the
  commonest sender address in its Sent mailbox. Read once and kept for 10 minutes.
- Every account and mailbox is reached (FR-831). Gmail's labels: a message is stored once (in
  All Mail) and listed in the label mailboxes through `labels`; a mailbox filter matches both
  the stored mailbox and the labels, so a message is found once, and each result names its
  labels (spec edge case "Gmail").
- Message files: `<V>/<account>/<mailbox path, each part + .mbox>/<store UUID>/Data/<ROWID / 1000,
  digits reversed, one folder each>/Messages/<ROWID>.emlx` or `.partial.emlx` (store UUID from
  `properties`; confirmed on the maintainer's Mac). Always from the database to the file, never the other
  way (stale files exist). A missing file or a partial one whose part is absent is said so
  (FR-807): "its text isn't on the Mac", never an empty message.
- `.emlx` = a byte count line, the RFC 822 message, Apple's property list. The message part is
  parsed with MimeFoundation (decided 2026-10-29), pinned by commit in `project.yml` as Sparkle is.
  Plain text is preferred; HTML-only mail becomes text with `HTMLText.fromHTML` (Files'
  converter: no WebKit, never loads anything; FR-803).
- Attachments of partial messages are in `…/Attachments/<ROWID>/<part>/<file name>` when Mail
  has downloaded them.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
