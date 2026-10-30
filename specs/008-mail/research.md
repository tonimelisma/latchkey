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
