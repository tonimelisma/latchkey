# 0095. Reading a message and its attachments (FR-803 to FR-805, FR-807)

- Status: accepted
- Date: 2026-10-29
- Alias: plan 008 D5 (`specs/008-mail/plan.md`, "D5. Reading a message and its attachments (FR-803 to FR-805, FR-807)")

## Context and problem

Decision D5 of spec 008's plan (Mail); requirements in
[requirements/mail.md](../requirements/mail.md). Requirement IDs it cites: none current.
The design it belongs to: [design/mail.md](../design/mail.md).

## Decision


- `mail_read` gives account, mailbox (labels), sender, recipients (to, cc), date, subject,
  unread/flagged, the text (paged), and each attachment's number, name, type, and size, with
  whether it is on the Mac. `conversation: true` lists the messages with the same
  `conversation_id`, newest first.
- `attachment` (number or file name): an image as an image (`ImagePrep`), a PDF or document as
  its text (`FileReader`, through a file written in Latchkey's own temporary folder and deleted
  at once), anything else by name, type, and size (FR-804). An attachment of a partial message
  that isn't downloaded is fetched by asking Mail to save it (the `saveAttachment` script; Mail
  downloads it), only when Latchkey is already allowed to control Mail; otherwise the answer
  says it isn't on the Mac. Mail is sandboxed, so it saves into a `Latchkey-<UUID>` folder in
  Downloads (a place Mail may write), which Latchkey reads and removes at once. A forward's
  original attachments are copied there too for Mail to attach, and removed two minutes after.
- An attachment's name is the sender's text and never becomes part of a path (security review,
  2026-10-29): Mail saves to a UUID name Latchkey chooses (keeping only a plain extension), files
  for reading are UUID-named, a forward's copy gets the name made harmless (no "/", ":", NUL,
  control characters, or leading dot) in a folder of its own, and a downloaded copy of Mail's is
  found by the index's part id and an exact name match in that folder's listing, then must
  resolve (symbolic links followed) to a regular file inside the folder (`MailPaths`).
- Reading never marks read. `mark_read: true` (Read & write only, D1) runs the change script's
  `mark_read` after reading (FR-805).

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
