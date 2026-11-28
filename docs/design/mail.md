# Mail: design

GOVERNS: `macos/App/Mail/`

Spec 008's plan (migrated from `specs/008-mail/plan.md`, titled "Plan 008: Mail — HOW"). What it must do:
[requirements/mail.md](../requirements/mail.md). Each decision Dn is an ADR, linked
where the decision stood.

Derived from `docs/requirements/mail.md` (approved 2026-10-29); evidence in `docs/research/2026-10-29-mail.md`. Every decision
names the requirements it serves. Tool schemas are in `docs/design/contracts/mail-tools.md`.

## D1. Tools Claude sees

Decision record: [ADR 0091](../adr/0091-tools-claude-sees.md).

## D2. Reading: the Envelope Index and the message files (FR-801, FR-803, FR-807, FR-831, FR-834)

Decision record: [ADR 0092](../adr/0092-reading-the-envelope-index-and-the-message-files.md).

## D3. Find filters (FR-801, SC-801)

Decision record: [ADR 0093](../adr/0093-find-filters.md).

## D4. Text search (FR-802)

Decision record: [ADR 0094](../adr/0094-text-search.md).

## D5. Reading a message and its attachments (FR-803 to FR-805, FR-807)

Decision record: [ADR 0095](../adr/0095-reading-a-message-and-its-attachments.md).

## D6. Changes through Mail's scripting, writing in Mail's window (FR-810, FR-811, FR-820 to FR-823)

Decision record: [ADR 0096](../adr/0096-changes-through-mails-scripting-writing-in-mails-window.md).

## D6a. Writing by scripting, the text in a signature for a moment (FR-841 to FR-845, 2026-11-05)

Decision record: [ADR 0097](../adr/0097-writing-by-scripting-the-text-in-a-signature-for-a-moment.md).

## D7. Sending confirmed in Sent (FR-823, FR-824)

Decision record: [ADR 0098](../adr/0098-sending-confirmed-in-sent.md).

## D8. Level, setup, permissions, activity (FR-830, FR-832, FR-833)

Decision record: [ADR 0099](../adr/0099-level-setup-permissions-activity.md).

## D9. Text by others (FR-806)

Decision record: [ADR 0100](../adr/0100-text-by-others.md).

## D10. Queued email while the Mac is locked (FR-835 to FR-837, decided 2026-11-02)

Decision record: [ADR 0101](../adr/0101-queued-email-while-the-mac-is-locked.md).

## D11. Mail held by an alert (FR-839)

Decision record: [ADR 0102](../adr/0102-mail-held-by-an-alert.md).

## Testing (Constitution VII)

- Tests first, against a generated Envelope Index (the real tables and columns, in a temporary
  folder per test, `MailFixture`) with `.emlx` files (plain, HTML-only, multipart with an image
  and a PDF, partial with a downloaded and a missing attachment, a Gmail message with labels),
  and a stand-in `ScriptRunner`. Never the maintainer's mail, never a real send.
- Tool names, levels, annotations (27 tools; Read only shows `mail_find` and `mail_read`
  without `mark_read`; Off none); every filter; paging; text search with its time limit and its
  "how far back"; HTML-only mail as text; partial and missing files said so; attachments as
  image, text, or name; others' text marked; unknown layout; change actions' script arguments
  and activity; delete to Trash; send confirmed, unconfirmed, wrong sender refused, draft.
  Every script compiles against Mail's dictionary (`ScriptSyntaxTests`).
- Writing (D6) against stand-ins for Mail's windows (`FakeWindows`) and the clipboard
  (`FakePasteboard`): tests never open, show, or drive a window, never touch the clipboard, and
  never send. A copied Message-ID refused; a response window for another message (subject,
  recipients, Bcc, attachments) closed unsent; added recipients exactly the request; a contact's
  name for its address; Mail's "Bcc myself" allowed, any other Bcc refused; a change between the
  check and Send; a cancelled call; a window that won't close; text marked as quoted; the
  clipboard marked, given back, and left alone when someone copied meanwhile.
- Live, on the maintainer's Mac, after install (parent session): find, read, and the change actions on a
  test message; one send to the maintainer's own address.

## Constitution check

| Principle | Result |
|---|---|
| I. No inbound connections | Pass: same outbound connection |
| II. Fail fast | Pass: every tool has a deadline; text search stops itself at 20 s; scripts end at 25 s; no prompt at call time (Automation checked without asking when reading) |
| III. Disabled means nonexistent | Pass: levels filter the tools; `mark_read` exists only at Read & write |
| IV. Good macOS citizen | Pass: Mail's own scripting and compose window, standard Automation, Accessibility, and Full Disk Access approvals; Mail's database only read; the Owner's clipboard lent only for a paste, marked transient, and given back |
| V. Self-hostable | Pass: nothing new on the relay |
| VI. Store the minimum | Pass: no copy of mail; attachment files written for reading are deleted at once; account names kept in memory 10 minutes; a queued message only until it is sent, fails, or is cancelled |
| VII. Test-first | Pass: tests above written first, against fixtures |
| VIII. Simplicity | Pass: one dependency, MimeFoundation (the maintainer's choice), for MIME parsing |
| IX. Open source | Pass: MimeFoundation is MIT (its swift-crypto and swift-certificates dependencies Apache-2.0) |
