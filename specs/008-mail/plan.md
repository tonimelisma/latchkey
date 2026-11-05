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

## D6. Changes through Mail's scripting, writing in Mail's window (FR-810, FR-811, FR-820 to FR-823)

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
- Writing (Toni, 2026-10-30): new messages, replies, forwards, and drafts are written in Mail's
  own compose window, driven through Accessibility, so they arrive as ordinary mail (no quote
  around Claude's text; research "Live check"). Mail's scripting never composes. The window works
  with the lid closed while the session is unlocked (checked live 2026-11-01: a message with a
  file sent and a draft saved, arriving exactly as with the lid open), but while the session is
  locked Mail opens no window Accessibility can use. So the only screen check is the lock (Toni,
  2026-11-01: working functionality first); the display being off or the lid closed is fine.
  When the Mac is locked or Latchkey lacks Accessibility, the answer says so plainly and nothing
  is sent; there is no fallback to scripted text. Closing a
  window also answers Mail's "Unable to Load Window" alert (OK), shown when a window is closed
  before its text area loaded. Nothing here is specific to one person's
  accounts. One email is written at a time (`ComposeQueue`). Steps (`MailCompose.run`):
  1. Open the window: a new message from a `mailto:` link with recipients and subject only (the
     text never goes in the link); a response by opening the original with `message://<Message-ID>`
     and choosing Mail's Reply (⌘R), Reply All (⇧⌘R), or Forward (⇧⌘F), so Mail writes its own
     quote and, for a forward, carries the original's attachments (US3.1, FR-820).
  2. A response's window is checked against the message Claude chose before anything is typed
     (security review 2026-10-30: anyone can send a message with a copied Message-ID, and
     `message://` opens one of them). Refused before opening when more than one message (not
     deleted) has that Message-ID, compared with and without angle brackets in any letter case;
     copies with the same sender and subject sent within 5 minutes count as one message (Inbox
     and Sent of a message to oneself, two mailboxes; 2026-11-01: 2% of a month's mail had such
     copies, differing only by seconds in the send time).
     After opening, the subject must be the original's (ignoring "Re:"/"Fwd:"); To and Cc may hold
     only the original's own response recipients: for Reply, its Reply-To (from the message file)
     or else its sender, and for a message the Owner sent, its To; Reply All adds its To and Cc;
     Forward fills in no one. At least one of the replied-to addresses must be there; Bcc may hold
     only the Owner's own addresses; a forward may carry only the original's attachments.
  3. Sender (FR-822): a reply or forward uses the account the original came to (its address the
     original was sent to); a new message the account Claude names (`from`: name or address), or
     Mail's default. Chosen in the From pop-up when it shows another; an address that isn't one of
     Mail's accounts' is refused before any window opens.
  4. Recipients added to a response, the text, and files. Text and recipients are put in through
     Accessibility (the selected text set at the cursor; recipients at the end of the field), not
     the clipboard. Only files, and text Mail didn't take that way, go by Edit → Paste, with the
     clipboard lent for that one paste (`ClipboardLoan`): Latchkey's items are marked
     `org.nspasteboard.TransientType`, `ConcealedType`, and `AutoGeneratedType`; the Owner's
     clipboard is saved first and put back right after; the change count is compared right
     before Paste, and if anything else wrote to the clipboard meanwhile nothing is pasted, the
     step fails, and their copy is kept.
  5. Every field read back through Accessibility and checked (`MailCompose.check`): the subject
     (exact for a new message); each recipient field holds exactly the requested addresses (a
     token is the address, "Name <address>", or the name Mail shows for it: the name in the
     original's header or the contact's name in Contacts; exact addresses are paired first, one
     to one, case-insensitively), plus for a response Mail's own recipients unchanged, and for a
     new message the Owner's own address only where Mail put it when the window opened
     ("Automatically Cc/Bcc myself"); the From; Claude's text at the top of the body and not
     marked as quoted; every file attached (Mail gets up to 15 s), and no other attachment. Then
     the fields are read once more and must not have changed, and a call cancelled meanwhile
     stops here.
  6. Send, or Save for a draft (FR-821). Send counts only when Mail closes the window; an alert
     from Mail is reported with its text.
- On any failure the window is closed without sending or saving (Mail's alert dismissed only by
  its Cancel button, then Don't Save), even when the call was cancelled; a compose window Mail
  opens after Latchkey stopped waiting is closed the same way. If a window can't be closed, the
  answer says it is still open, unsent. The Owner's front app is put back after.
- Activity and notifications as for every write: a send (confirmed or not, D7) and a saved draft
  each record "Claude sent an email …" / "Claude saved a draft …"; refusals record nothing sent.

## D6a. Writing by scripting, the text in a signature for a moment (FR-841 to FR-845, 2026-11-05)

Reverses D6's "Mail's scripting never composes" for messages without attachments (research
"Writing while locked"). Text set as an outgoing message's `content` arrives quoted; text that
Mail itself puts in as a **signature** arrives as ordinary text, above Mail's quote in a reply or
forward, with Mail's own threading headers (checked live, unlocked, 2026-11-05). Needs no window,
so it works locked, with the lid closed, and without Accessibility; Mail never comes forward.

- Routing (`MailWrite.compose`): no files → `MailSignatureWriter` always. Files and Mail's window
  usable (`ComposeWindows.unavailable()` is nil) → the window (D6, FR-842). Files and the window
  unusable: a new message → `MailSignatureWriter`, the answer saying the files are above the text;
  a reply or forward → refused before anything is made, naming sending without the file, a new
  message with the file, or `mail_queue` (FR-843, FR-835).
- `MailSignatureWriter.makeScript` (one script run): removes signatures named `Latchkey message …`
  left by a cut-off write; makes the message (`make new outgoing message … visible:false`, or
  `reply`/`forward` of the exact message by account, mailbox, and id, `opening window false`);
  prints Mail's own recipients; sets the sender; adds recipients; makes the signature (a fresh
  UUID name, `content` the text), sets it as the message's signature, waits 1 s; attaches files
  (new messages only); deletes the signature (the message keeps the text: checked live); prints
  the id, subject, From, and recipients. Any error removes the signature and closes the message.
- Swift checks (FR-844): Mail's own recipients against the original (`checkPrefill`, as D6 step
  2: the place is exact, so the Message-ID count of D6 isn't needed), then subject, From, and every
  recipient (`MailCompose.check`, `content: false`: text and files can't be read back by
  scripting). Any difference: `finishScript close`, nothing sent. Cancelled meanwhile: closed.
- `finishScript send` or `save` (save waits 3 s before closing, as D6). A failure at send is
  "Mail may not have sent it" (`afterSend`), never resent (FR-823, FR-838). Then D7.
- One write at a time (`ComposeQueue`), so two signatures never meet. Env `byScript` (true in the
  app; the window tests set it false).
- Window route fix (docs/use-cases.md, forward of 2026-11-04, "To field has Toni Melisma, which
  wasn't asked for"): Mail was slow to turn the typed address into a token, so it was typed again
  and showed twice; `MailCompose.pair` no longer counts a repeat of a token already paired with an
  asked address as another recipient. Such forwards now go by scripting anyway.
- Known limits: a reply's text goes above the quote only while Mail's "Place signature above
  quoted text" is on (Mail's default; no scripting property reads it); a new message's text
  starts after one empty line; with files written by scripting, a plain-text reader sees an
  object character where the files are; a draft's plain part is empty until Mail sends it (Mail
  rebuilds it); signatures sync through iCloud, so another Mac may see one for about a second;
  an Owner's default signature isn't added (the message's signature is Latchkey's).
- Checked by `macos/scripts/mail-check.sh <to> script` (new, draft, reply, forward; each sent copy
  read back unquoted; everything swept to the Trash) and the screen-state cases
  `mail.*_locked` / `mail.*_lid` for the coordinator.

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

## D10. Queued email while the Mac is locked (FR-835 to FR-837, Toni 2026-11-02)

Since 2026-11-05 (D6a) only a reply or forward with attachments needs the queue while locked.
Mail's window can't be used while the session is locked (checked live 2026-11-01), and Latchkey
never gets around the lock (spec 001 FR-661). Options Toni was shown: refuse; queue until the
next unlock; send at once through Mail's scripting (text shows as quoted in other apps). Chosen:
a tool of its own, `mail_queue` (add with mail_send's inputs, list, cancel), so Claude decides
with the Owner whether waiting is fine; mail_send's locked answer names it. The queue
(`MailQueue`) is one JSON file in the app's support folder, mode 0600, removed when empty and
by uninstalling; ids q1, q2. On macOS's `com.apple.screenIsUnlocked` (and at start when
unlocked), while Mail is Read & write, `AppModel.sendQueuedMail` waits 3 s, then sends each
item, oldest first, through `MailWrite.send` (all of D6 and D7's checks), removing it first so
it is never sent twice, and notifies the Owner and the activity log of each result. FR-838: an
answer starting "Nothing was sent" (every check before Send, and Mail's window failing) puts the
item back in its place with a count of failed tries and the last reason; anything else (an
unconfirmed or unreadable Sent copy) drops it, since trying again could send it twice. Each round
tries each item once; a round that put one back schedules another in 300 s while unlocked
(unlock and start rounds cancel it; one round at a time). Three failed tries drop it.
Security review (2026-11-02): a failure after Send was pressed (Mail's window stayed open, or
showed a sheet) is answered "Mail may not have sent it: …", never "Nothing was sent", so the
queue drops it; and the ids of items being tried stay reserved, so one queued meanwhile can't
share an id with one put back. Low-level
choices: no expiry (a queued message waits however long the Mac stays locked; the Owner can ask
Claude to cancel it); attachments are checked when queued and again when sent.

## D11. Mail held by an alert (FR-839)

Mail's app-modal alerts (seen 2026-11-01, with the lid closed: "The message … could not be moved
to the mailbox … Invalid base64 string for MIME content", Mail failing to save its own sent copy
to Exchange after the message was delivered) block every script until answered, and Mail keeps
answering Accessibility meanwhile. So when a Mail script times out (`MailCapability.run`, which
every Mail tool and the queue go through), `AXMailWindows.alert()` looks at Mail's windows, only
if Mail is running and Accessibility is on: the first `AXDialog`/`AXSystemDialog` window, or a
sheet on a window that isn't a compose window (a compose window's sheets are D6's). Pressed only
when it is an alert window (a sheet is only named) whose one control, anywhere inside it, is its
default button (no text field, checkbox, pop-up; 0.8.88, security review), since such an alert only informs; the answer says what it said and to try
again, and `alsoDone` notifies the Owner. More buttons: a choice (it could be "Send Anyway"),
named with its buttons for someone at the Mac. Options weighed: report only (leaves Mail held
until the Owner is back, which is what happened); press any alert's default button (could
choose for the Owner); press only a lone button (chosen). Found by repeating the send: the same
file through Latchkey and through Mail's own scripting both saved their sent copy while
unlocked; Mail's failed copy had been rewritten by Mail before its upload, so the cause is in
Mail's later upload, not in what Latchkey hands it.

## Testing (Constitution VII)

- Tests first, against a generated Envelope Index (the real tables and columns, in a temporary
  folder per test, `MailFixture`) with `.emlx` files (plain, HTML-only, multipart with an image
  and a PDF, partial with a downloaded and a missing attachment, a Gmail message with labels),
  and a stand-in `ScriptRunner`. Never Toni's mail, never a real send.
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
- Live, on Toni's Mac, after install (parent session): find, read, and the change actions on a
  test message; one send to Toni's own address.

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
| VIII. Simplicity | Pass: one dependency, MimeFoundation (Toni's choice), for MIME parsing |
| IX. Open source | Pass: MimeFoundation is MIT (its swift-crypto and swift-certificates dependencies Apache-2.0) |
