# Plan 008: Mail — HOW

Derived from `spec.md` (approved by Toni, 2026-10-29); evidence in `research.md`. Every decision
names the requirements it serves. Tool schemas are in `contracts/mail-tools.md`.

## D1. Tools Claude sees

Four tools, in the find/read/change pattern of the other capabilities, with sending a tool of
its own (FR-820, Toni 2026-10-29). 27 tools in all.

| Tool | Level | readOnly | destructive | openWorld | Serves |
|---|---|---|---|---|---|
| `mail_find` | Read only | yes | no | no | FR-801, FR-802, FR-806, FR-807, FR-831 |
| `mail_read` | Read only | yes | no | no | FR-803 to FR-807 |
| `mail_change` | Read & write | no | yes | no | FR-810, FR-811, FR-821, FR-822 |
| `mail_send` | Read & write | no | no | yes | FR-820, FR-822 to FR-824 |

- `mail_find` with no arguments lists the accounts and mailboxes with their unread counts
  (FR-801). With filters it lists messages newest first, a page at a time (`offset`). With
  `text`, it searches messages' text (D4).
- `mail_read` reads one message (`id`), its conversation (`conversation: true`), or one
  attachment (`attachment`). Long text comes in pages (`offset`, `ResultLimit`).
- `mark_read` on `mail_read` (FR-805) exists only at Read & write: at that level the
  capability's `mail_read` is replaced by the same tool with the extra argument (D7). The tool
  keeps `readOnlyHint: true` at both levels, since marking read is what Mail does when a message
  is shown; a write hint would make Claude's apps ask before every read. Its description tells
  Claude to pass it when the Owner will see what the message says (Claude shows or summarises
  it) and not for its own lookups (Toni, 2026-10-29).
- `mail_change` actions: `mark_read`, `mark_unread`, `flag`, `unflag`, `move` (to a mailbox of
  the same account), `junk`, `not_junk`, `delete` (to the account's Trash), and `draft` (a new
  message, reply, or forward saved in the account's Drafts). `id` or `ids` for several.
- `mail_send`: a new message, a reply (`reply_to`, `reply_all`), or a forward (`forward`), with
  `text`, `attachments` (paths), and `from` (an account's name or address).
- Deadlines (`latchkey/deadline_ms`): `mail_find` 30 s (text search stops itself at 20 s),
  `mail_read` 30 s (an attachment may need downloading), `mail_change` 60 s, `mail_send` 90 s
  (attachments, then the confirmation in Sent).
- Results are text only, with ids Claude passes back (`.claude/rules/macos.md`).

## D2. Reading: the Envelope Index and the message files (FR-801, FR-803, FR-807, FR-831, FR-834)

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
  `properties`; confirmed on Toni's Mac). Always from the database to the file, never the other
  way (stale files exist). A missing file or a partial one whose part is absent is said so
  (FR-807): "its text isn't on the Mac", never an empty message.
- `.emlx` = a byte count line, the RFC 822 message, Apple's property list. The message part is
  parsed with MimeFoundation (Toni, 2026-10-29), pinned by commit in `project.yml` as Sparkle is.
  Plain text is preferred; HTML-only mail becomes text with `HTMLText.fromHTML` (Files'
  converter: no WebKit, never loads anything; FR-803).
- Attachments of partial messages are in `…/Attachments/<ROWID>/<part>/<file name>` when Mail
  has downloaded them.

## D3. Find filters (FR-801, SC-801)

SQL over `messages`, `subjects`, `addresses`, `recipients`, `mailboxes`, `labels`,
`attachments`, `deleted = 0`, `ORDER BY date_received DESC`, `LIMIT`/`OFFSET`: `from` (sender
address or name, `LIKE`), `to` (any recipient), `subject`, `account` (name, address, or id),
`mailbox` (name, e.g. "Inbox", in every account unless `account` is given; matches the last part
of the mailbox's path, so "Inbox" finds Gmail's `INBOX` label and Exchange's `Inbox`), `since`,
`until`, `unread`, `flagged`, `has_attachments`. Default 25 results, at most 100; the answer says
how to get the next page. Research measured 0.02–0.4 s for such queries over 100,000 messages.

## D4. Text search (FR-802)

No copy of mail is kept (Toni, 2026-10-29). `text` runs the other filters' query newest first
in batches and reads each message's file, stopping at the requested number of hits or after
20 seconds (`searchBudget`), whichever comes first. The answer says the date of the oldest
message it read and, when it stopped early, to call again with `until` set to that date to look
further back. Messages whose text isn't on the Mac are counted and named in the answer.

## D5. Reading a message and its attachments (FR-803 to FR-805, FR-807)

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

## D6. Actions through Mail's scripting (FR-810, FR-811, FR-820 to FR-823)

- Scripts run by Latchkey itself with `OSAScriptRunner` (not through Shell; Toni,
  2026-10-29), arguments after `--`, never in the script text. Mail is started by scripting when
  it isn't running.
- Messages are found by account id, mailbox path, and `id` (the database row; 0.4 s live).
  For a Gmail message, the mailbox used is its first label other than All Mail (so moving it
  relabels it, spec edge case), else All Mail.
- `change` script: `mark_read`/`mark_unread` (`read status`), `flag`/`unflag` (`flagged
  status`), `junk`/`not_junk` (`junk mail status`), `move` (to the named mailbox of the same
  account), `delete` (to the account's own Trash, found as the child of Mail's `trash mailbox`
  whose account is the message's: research "Ids and paths"; never `delete`, which follows each
  account's setting; FR-811). A message not found (moved or deleted meanwhile) is reported by id.
- `compose` script: a new message (`make new outgoing message`), a reply (`reply … without
  opening window`, `with reply to all` for all), or a forward (`forward … without opening
  window`). Then sender, recipients, subject, the text, and attachments (`make new attachment …
  at after the last paragraph`, then a wait until Mail shows them all, up to 15 s; research
  "attachments can go out empty"). Then `send`, or `save` for a draft (FR-821).
- Sender (FR-822): a reply or forward uses the account the original came to; a new message the
  account Claude names (`from`: name or address), or Mail's default. The script sets `sender`
  and reads it back; a mismatch stops before sending (research: a wrong sender is silently
  replaced). An address that isn't one of Mail's accounts' is refused before any script.
- Quoting: setting a reply's text replaces Mail's own quote, so Latchkey writes the quote
  itself ("On <date>, <sender> wrote:" and the original's text with "> "); a forward gets
  "Begin forwarded message:" with the original's headers and text, and the original's
  attachments re-attached from the Mac (US3.1, FR-820).
- Known limit, checked live on macOS 27 (research "Live check: scripted text arrives quoted"):
  Mail wraps text set by scripting in a citation, so other mail apps show it as quoted. The
  spec's edge case leaves the way to send to Toni; until he chooses, this plan sends through
  scripting as decided.

## D7. Sending confirmed in Sent (FR-823, FR-824)

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

## D8. Level, setup, permissions, activity (FR-830, FR-832, FR-833)

- `CapabilityRegistry.mail`, levels Off, Read only, Read & write. A new capability id is
  absent from stored levels, so it starts at the default, Read & write, on first launch and on
  the update (FR-830). The registry lets a write tool replace a read tool of the same name at
  Read & write (for `mail_read`'s `mark_read`).
- Full Disk Access: already a setup step for any capability on; `Permissions.hasFullDiskAccess`
  also tries the Envelope Index. Missing: the tools say "turn on Full Disk Access" (FR-833).
- Automation for Mail (`com.apple.mail`): a setup step and Permissions-tab row while Mail is
  Read & write, like Notes and Messages (FR-833). A script refused with -1743 says plainly what
  to turn on.
- Activity: every change, draft, and send sets `ToolResult.activity` ("Claude sent an email to
  Sarah: «Lease»", "Claude moved 2 emails to Trash"), which becomes the notification and the
  activity entry (FR-832), as Notes and Messages do. `mark_read` on `mail_read` does the same.

## D9. Text by others (FR-806)

Every result starts with the marking line Messages uses and puts every sender name, address,
subject, message text, and attachment name in «» (`MessagesCapability.quote`), so nothing inside
can pose as the end of the quote.

## Testing (Constitution VII)

- Tests first, against a generated Envelope Index (the real tables and columns, in a temporary
  folder per test, `MailFixture`) with `.emlx` files (plain, HTML-only, multipart with an image
  and a PDF, partial with a downloaded and a missing attachment, a Gmail message with labels),
  and a stand-in `ScriptRunner`. Never Toni's mail, never a real send.
- Tool names, levels, annotations (27 tools; Read only shows `mail_find` and `mail_read`
  without `mark_read`; Off none); every filter; paging; text search with its time limit and its
  "how far back"; HTML-only mail as text; partial and missing files said so; attachments as
  image, text, or name; others' text marked; unknown layout; change actions' script arguments
  and activity; delete to Trash; send confirmed, unconfirmed, wrong sender refused, reply quote,
  draft. Every script compiles against Mail's dictionary (`ScriptSyntaxTests`).
- Live, on Toni's Mac, after install (parent session): find, read, and the change actions on a
  test message; one send to Toni's own address.

## Constitution check

| Principle | Result |
|---|---|
| I. No inbound connections | Pass: same outbound connection |
| II. Fail fast | Pass: every tool has a deadline; text search stops itself at 20 s; scripts end at 25 s; no prompt at call time (Automation checked without asking when reading) |
| III. Disabled means nonexistent | Pass: levels filter the tools; `mark_read` exists only at Read & write |
| IV. Good macOS citizen | Pass: Mail's own scripting and standard Automation and Full Disk Access approvals; Mail's database only read |
| V. Self-hostable | Pass: nothing new on the relay |
| VI. Store the minimum | Pass: no copy of mail; attachment files written for reading are deleted at once; account names kept in memory 10 minutes |
| VII. Test-first | Pass: tests above written first, against fixtures |
| VIII. Simplicity | Pass: one dependency, MimeFoundation (Toni's choice), for MIME parsing |
| IX. Open source | Pass: MimeFoundation is MIT (its swift-crypto and swift-certificates dependencies Apache-2.0) |
