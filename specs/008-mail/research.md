# Spec 008: Mail — research

Researched 2026-10-29 on Toni's Mac (macOS 27.0.1, Mail 16.0), read-only: counts and schema
only, no message text read, nothing sent or changed.

## What this Mac has

`~/Library/Mail/V10`, 5.7 GB: an Exchange account (`ews://`, 46,527 messages), two Gmail
accounts (`imap://`, 60,168 and 187), an empty IMAP account (probably iCloud), On My Mac.

## Reading and searching

- **Envelope Index** (`~/Library/Mail/V10/MailData/Envelope Index`, SQLite in WAL mode, 160 MB,
  100,647 messages in 38 mailboxes). Needs Full Disk Access (Latchkey has it for Messages); Mail
  needn't run. Tables: `messages` (sender, subject, summary, dates in Unix seconds, mailbox,
  read, flagged, deleted, size, conversation), `recipients`, `addresses`, `subjects`,
  `mailboxes` (url, totals, `source` for Gmail's label folders), `labels`, `attachments`,
  `message_global_data` (Message-ID). No message text. Version stamp in `properties`
  (`version` 4, `minor_version` 90006).
  Timings: subject contains "invoice" over 100k messages 0.38 s; sender 0.02 s; newest 50
  0.007 s. Open with `mode=ro`, never `immutable=1` (that skips the WAL and misses new mail);
  never write (Mail's triggers keep counts). Undocumented and changing (V2…V10, new columns):
  check columns at start and say plainly when the layout is unknown (FR-834), as the Notes
  reader does ([sweetrb #342](https://github.com/sweetrb/apple-mail-mcp/issues/342)).
- **Gmail**: a message is stored once under `[Gmail]/All Mail`; Inbox and labels are virtual
  mailboxes through `labels` (6,339 rows here).
- **Message files (`.emlx`)**: 100,754, of which 9,599 partial (attachments on the server).
  A byte count, the RFC 822 message, an Apple plist. Path from the database row:
  `<account>/<mailbox>.mbox/<UUID>/Data/<ROWID/1000 digits reversed>/Messages/<ROWID>.emlx`
  (confirmed). Exchange messages have files here too. Stale files exist (rows deleted): always
  go from the database to the file. Listing all 2.1 s; a brute-force text scan of all 159 s.
- **Spotlight**: no longer indexes mail (0 `com.apple.mail.emlx` items). Not usable.
- **AppleScript reads**: about 45 s for the newest 20 of a 44,000-message mailbox (sweetrb);
  timeouts and quietly incomplete results reported by every AppleScript-first server. Used for
  actions only.
- **MailKit**: Mail extensions (blocking, actions on incoming mail, compose); no general read
  or search. Doesn't fit.

## Actions (Mail's scripting dictionary)

`send`, `reply` (to all), `forward`, `move … to`, `delete`, `save` (drafts; attachments to a
file), read / flagged / junk status. Writing is plain or rich text (`html content` does
nothing). Mail must run for actions (scripting starts it); compose windows can stay hidden.
Automation for Mail is granted on this Mac. Scripts must run outside the Shell fence's
sandbox: apps refuse Apple events from sandboxed programs (found here; fixed in Shell 0.8.44).
Known problems:
- Text set by script can arrive marked as quoted in other mail apps since Mail 16 (FB11734014;
  [Apple forum](https://developer.apple.com/forums/thread/738842)). Needs one live check on
  macOS 27 before sending is built.
- Attachments can go out empty if `send` runs before Mail attached them; confirm in Sent.
- A wrong sender account is silently replaced by the default (sweetrb #291): check `sender`
  against the account's addresses.
- A send that timed out may have gone: never send again; confirm by Message-ID in Sent.
- `delete` follows each account's setting; moving to the account's `trash mailbox` is exact.

## Existing servers

[sweetrb/apple-mail-mcp](https://github.com/sweetrb/apple-mail-mcp) (AppleScript first, many
tools, slow search), [PsychQuant/che-apple-mail-mcp](https://github.com/psychquant/che-apple-mail-mcp)
(Envelope Index + `.emlx`, composes through `mailto:` and keystrokes to avoid the quote
problem), [imdinu/apple-mail-mcp](https://github.com/imdinu/apple-mail-mcp) (read-only, own
full-text index). Common complaints: AppleScript timeouts, incomplete results presented as
complete, empty attachments, the quote wrapper, the wrong sending account, Gmail duplicates.

## Risks

Sending can't be undone (Claude's apps ask per call; Latchkey adds nothing, as Messages).
Email is the main real-world path for injected instructions (EchoLeak, CVE-2025-32711,
[arXiv 2509.10540](https://arxiv.org/abs/2509.10540)): text by others is marked as such
(FR-806), HTML is turned into text and nothing remote is loaded. Attachments: never opened,
only read as text or images. Large mailboxes: always a page at a time. Several accounts and
same-named mailboxes: every result names its account.

## Toni's choices (2026-10-29)

A separate send tool; Read & write includes sending; text search newest first within a time
limit, no copy of mail kept; delete moves to the account's Trash; every account; move, junk,
read and flag included, mailbox management, rules, and mail merge left out; reading leaves
mail unread, and Claude marks it read when the Owner sees what it says; starts at Read & write.

## Approach (for the plan)

Read and search from the Envelope Index (read-only) and the `.emlx` files; act through Mail's
scripting; confirm sends in the Sent mailbox by Message-ID.

## Live check: scripted text arrives quoted (2026-10-29, macOS 27.0.1, Mail 16.0)

One test message, as Toni approved: Mail's scripting (`make new outgoing message` with
`content` and `visible:false`, one `to recipient`, `send`), from Mail's default account (it chose
the Exchange account, the Owner's own address), to that same address, subject "Latchkey test: please
ignore". The sent copy (Sent Items, read-only from the Envelope Index and its `.emlx`):

- The plain part is quoted-printable with every line starting `> `.
- The HTML part wraps the text in `<div class="Apple-Mail-URLShareWrapperClass"><blockquote
  type="cite" style="border-left-style: none; …">`. Mail hides the quote with that style; other
  mail apps (and every plain-text reader) show the text as quoted.

**The problem happens on macOS 27.** It is FB11734014, open since Ventura. Known ways round it,
none tested here (nothing else may be sent):

| Way | Pros | Cons |
|---|---|---|
| Mail's scripting, as built (`content`) | Unattended, any account, reply/forward threading by Mail, Sent copy by Mail | Text shows as quoted in other apps |
| Setting `content` after creating, or `html content` | Same as above | Reported not to help: every way of setting the body through scripting gets the wrapper, and re-setting it re-applies it ([che-apple-mail-mcp 2.17.0](https://github.com/PsychQuant/che-apple-mail-mcp/releases/tag/v2.17.0)) |
| `mailto:` into a compose window, then keystrokes (che-apple-mail-mcp) | Mail's own compose path, no wrapper | Needs Accessibility; a window appears on the Owner's screen and keys are typed into it; new messages only (not reply/forward), no choice of sender; can't confirm the send by itself; breaks when the Owner types meanwhile |
| Pasting into the compose window (sweetrb "native editor") | No wrapper; replies too | Same as above plus it borrows the clipboard |
| SMTP directly (sweetrb) | Clean MIME, any client shows it right | Needs each account's server and an app password in the Keychain; bypasses Mail (Sent copy by IMAP); Exchange may not allow SMTP |

Toni chose (2026-10-30) Mail's compose window through Accessibility, for new messages, replies,
forwards, and drafts alike (plan D6): text and recipients set through Accessibility, files
pasted; refused plainly when the screen is off or locked or Accessibility is missing, never
falling back to scripted text.

## Live check: the compose window with the lid closed (2026-11-01, macOS 27.0.1)

`macos/scripts/mail-check.sh` ran Latchkey's own compose code from a terminal with
Accessibility, the lid closed. A window opened, its fields read, a draft saved, and a message
sent, with a file too; the sent copy is plain text (7bit), the two lines exactly as given, the
same as with the lid open. Mail's To field showed the account's full name ("Toni Melisma"), not
the address; Accessibility gives no address for a recipient token. A window closed before its
text area loaded shows "Unable to Load Window … Are you sure you want to close it?" (OK,
Cancel). Those runs turned out to be while the session was still unlocked: with the lid closed,
macOS keeps drawing the screen until a few minutes after the last activity, then locks. Once
locked, Mail opened no window Accessibility could use ("Mail didn't open a new message window";
its windows showed only as "Mail" with nothing inside), with the display off or woken. So the
screen check became a lock check (Toni, 2026-11-01).

## Ids and paths (checked live 2026-10-29, read-only)

- Mail's scripting `id` of a message is its `messages.ROWID`; `first message of mailbox "Sent
  Items" of account id "<UUID>" whose id is N` answered in 0.4 s. Account ids are the UUIDs in
  mailbox URLs and the account folders under `V10`.
- Each account's Trash, Sent, Junk, and Drafts are the children of Mail's `trash mailbox`, `sent
  mailbox`, `junk mailbox`, `drafts mailbox` whose `account` is it (Exchange: Deleted Items, Sent
  Items, Junk Email, Drafts; Gmail: Trash or Bin, Sent Mail, Spam, Drafts). `account` has no
  trash property of its own (error -1700).
- The `.emlx` folder under the mailbox is named after the Envelope Index's `UUID` property;
  ROWID 99006 is under `Data/9/9/Messages/`, 100833 under `Data/0/0/1/Messages/`. Downloaded
  attachments of partial messages: `Data/…/Attachments/<ROWID>/<part>/<file name>`.
- `message_global_data.message_id_header` holds the Message-ID with its angle brackets; the sent
  copy appeared in Sent Items within seconds (`date_received` a few seconds after the send).
- `recipients.type`: 0 To, 1 Cc (2 is taken as Bcc). `messages.read`/`flagged` are columns; the
  `flags` bit 1 is read too.
- Gmail label mailboxes have `source` = the All Mail mailbox's ROWID.

## Low-level choices (plan)

- **Account names when Mail can't be asked**: (a) Mail's scripting only (fails when Mail isn't
  running or not yet allowed), (b) `~/Library/Accounts/Accounts4.sqlite` (undocumented, another
  layout to track), (c) scripting when allowed and running, else kind plus the commonest Sent
  address. Chose (c): reading never needs Mail or a prompt.
- **Which mailbox to address a Gmail message through**: (a) always All Mail (moving would add a
  label without leaving Inbox), (b) its first label other than All Mail. Chose (b), so a move
  from Inbox relabels it, as in Mail.
- **Finding the Sent copy**: Mail's scripting can't set or read a Message-ID before sending. (a)
  match by subject, first recipient, and time in the account's Sent mailbox, then read its
  Message-ID; (b) a marker in the text (changes what the recipient sees). Chose (a).
- **Reply quote**: setting a reply's text through scripting replaces Mail's quote (sweetrb #7).
  Withdrawn with scripted composing (2026-10-30): Mail's own Reply and Forward write the quote.

## Compose window choices (security review 2026-10-30)

- **Which message `message://` opens**: the link names a Message-ID, which anyone can copy into
  a message of their own. (a) open the exact message object through Mail's scripting by
  account, mailbox, and id (`open`, or `reply … with opening window`): untested live, and
  whether a scripted reply window gets the citation wrapper is unknown; (b) keep the link, refuse
  when more than one message has the Message-ID, and compare the window Mail opened with the
  store (subject, recipients, attachments). Chose (b): it can be checked without a live send.
  Counting: rows not deleted (a message being moved leaves a deleted row behind; Mail's link
  doesn't open those), the header with and without angle brackets, any letter case (stricter
  than Mail's own match).
- **What a response may prefill**: Reply goes to Reply-To (read from the message file; without
  the file only the sender counts, so a window addressed elsewhere is refused), or the sender;
  for a message the Owner sent, its To. Reply All adds To and Cc. The Owner's own addresses may
  appear anywhere, for Mail's "Automatically Cc/Bcc myself". Placement between To and Cc isn't
  checked (Mail's choice), only that nothing else is there.
- **Matching a token to an address**: Mail shows a contact's name instead of the address. (a)
  require the address in every token (fails for every contact); (b) accept the address, "Name
  <address>", or a name known for that address: from the original's header, from the request's
  "Name <address>", or Contacts (`ContactBook`, read only when already allowed, no prompt).
  Chose (b); exact addresses are paired first, one to one, so a name can't stand in for a second
  address. A name on its own matches nothing else.
- **Putting text in**: (a) the clipboard (borrows it; clipboard managers keep a copy); (b)
  Accessibility's selected text set at the cursor (WebKit and text fields take it as typed, at
  the cursor, so above Mail's quote). Chose (b), with (a) only when Mail shows no change. Files
  can only be pasted (or picked in a file dialog, which is worse).
- **Lending the clipboard**: marked with nspasteboard.org's `TransientType`, `ConcealedType`, and
  `AutoGeneratedType` (clipboard managers skip such items); the Owner's items saved as their
  types' data and put back right after each paste (not at the end); the change count noted
  after writing and compared right before Paste: changed means someone copied, so nothing is
  pasted and their copy is not overwritten when giving back.
- **Closing on failure**: Mail's alert is dismissed only by its Cancel button (another button
  can be "Send Anyway"), then Don't Save. Cleanup runs in a task of its own so a cancelled call
  still waits for the window to close.
- **HTML to text**: (a) `NSAttributedString` HTML import (WebKit, may load remote content, main
  thread), (b) Files' `HTMLText` (Foundation's XML parser, loads nothing). Chose (b).
- **`mark_read` at Read only**: (a) offered at every level, (b) only at Read & write (marking is
  a change, FR-810). Chose (b), with `mail_read` keeping its read-only hint.
- **MimeFoundation pin**: the project has no release tags; pinned to commit
  `dcb6746729d20cf00c42ad6453b4637a075f7d0b` (2026-02-11, "Fix for iOS"), as Sparkle is pinned by
  commit. Its swift-crypto and swift-certificates (Apache-2.0) resolve by Xcode's resolution
  of its `from:` ranges.

## Writing while locked (2026-11-05, macOS 27.0.1, Mail 16.0)

Toni mostly uses Claude from his phone with the Mac locked or the lid closed, when Mail's
window can't be used (2026-11-01). Options, least to most intrusive, tried live where possible
(unlocked; test mail only to the Owner's own address, every copy moved to Deleted Items after):

| Option | Tried | Result | Pros | Cons |
|---|---|---|---|---|
| Scripting, text as `content` (`visible:false`) | 2026-10-29 | Text arrives quoted (`> ` in plain, `blockquote type=cite` in HTML) | No window | Quoted in every other mail app |
| **Scripting, text as a temporary Mail signature** (`make new signature`, `set message signature of m`) | Yes | New message: plain part and HTML unquoted, no wrapper, one empty line first. Reply: text above Mail's quote, In-Reply-To/References set. Forward: text above "Begin forwarded message", original attachments carried. Draft: in Drafts, HTML right (plain part empty until sent). Deleting the signature before Send keeps the text | No window, no Accessibility, works whatever the screen does; Mail's own composer, threading, and Sent copy; recipients read back as addresses | Mail's signature list changes for about a second (syncs through iCloud); relies on "Place signature above quoted text" (Mail's default) for replies; leftovers if cut off (removed by the next write) |
| Same, plus files attached by scripting | Yes | New message: files go above the text, an empty `blockquote` wrapper around them, an object character in the plain part; text itself unquoted. Reply: the quoted original is dropped (as 2026-11-03) | Files while locked for new messages | Layout worse than the window; unusable for replies and forwards |
| Accessibility on the compose window while locked | 2026-11-01 | Mail opens no window Accessibility can use while locked | — | Doesn't work |
| `mailto:` / `message://` and keystrokes | 2026-10-30 | Needs a window | — | Same as above |
| SMTP or Exchange (EWS/Graph) directly | Not tried | — | Clean MIME | Needs each account's password or OAuth token, which Mail keeps to itself (Keychain items Latchkey may not read); bypasses Mail's Sent copy; another protocol per account kind. Rejected |
| Writing a draft `.emlx` into Mail's store | Not tried | — | — | Mail's store is read-only for Latchkey (plan D2); Mail may overwrite or ignore it. Rejected |
| Editing Mail's signature files on disk (`MailData/Signatures`, rich text, files) | Not tried | — | Formatting, files | Undocumented, Mail caches them, iCloud sync. Rejected |
| Queue until unlock (`mail_queue`, D10) | Built | Works | Mail's window | Waits for the Owner |

Chosen (plan D6a): the temporary signature for every message without files, in every screen
state (also unlocked: nothing comes forward, no Accessibility needed); the window for files while
it can be used; while it can't, scripting for a new message with files and a refusal naming the
queue for a reply or forward with files. The earlier helper's idea (2026-11-04, "a scripted
writer that puts the text in through a temporary Mail signature") is this option; it left no code.

Low-level choices (decided here):
- **Signature name**: `Latchkey message <UUID>`; (a) one fixed name (two writes could clash; the
  queue allows one at a time anyway), (b) a fresh UUID each time, leftovers removed by prefix.
  Chose (b).
- **When the signature is deleted**: (a) after Send (lives several seconds, through Mail's send),
  (b) right after Mail put the text in, before the checks (checked live: the sent text stays).
  Chose (b).
- **Checks before Send**: (a) none (the exact message object is used), (b) the window's recipient
  and subject checks on what scripting reads back. Chose (b); scripting reads addresses, so names
  Mail shows (the forward bug) don't matter. The text can't be read back (`content` of a hidden
  message is empty), so it is checked live by `mail-check.sh script` instead.
- **One script or several**: the message is made, filled, and read back in one script run (fewer
  Apple events, the signature gone before Swift checks); send, save, or close in a second.
- **Outgoing messages after Send**: Mail keeps sent `outgoing message` objects in memory until it
  quits (`close` refuses them); harmless, nothing is stored.
- **The forward bug** (docs/use-cases.md, 2026-11-04): Mail's window showed "Toni Melisma" once
  more than asked; with the window, an address Mail was slow to turn into a token was typed a
  second time (`addRecipients`' second way). Options: (a) skip any repeated token; (b) skip a
  repeat only when it is an exact address already paired; (c) resolve names to addresses first
  (Mail's tokens give none). Chose (b) after the security review (2026-11-05): with (a) a second
  person sharing a name could slip through. Such forwards now go by scripting, which reads
  addresses.

**Locked: not yet confirmed.** `mail-check.sh <to> script` passed its four writes twice unlocked
(each sent copy unquoted, a reply's and forward's text above the quote). During a third run the
Mac locked by itself; from then Mail answered no Apple event at all (even reading `outgoing
messages` timed out with -1712) while its main thread sat idle, as on 2026-11-03 ("a send that
began just before the Mac locked froze Mail until the unlock"). Whether Mail answers scripting
when a write *starts* on a locked Mac is what the screen-state cases (`mail.send`, `mail.reply`,
`mail.forward`, `mail.draft`, `mail.send_file`, `mail.reply_file` in the locked states) settle.
If Mail doesn't answer, every script ends at 25 s: before Send that is "Nothing was sent" (the
queue can take it), at Send "Mail may not have sent it" (never resent).
