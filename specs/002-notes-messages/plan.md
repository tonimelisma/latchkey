# Plan 002: Notes and Messages — HOW

Derived from `spec.md`; evidence in `research.md`. Every decision names the requirements it serves.

## D1. Tools Claude sees

Claude sees consolidated tools (Toni, 2026-10-23: 15 tools in all, from 45): the table below. The operations listed after it are their internals, each reached by an `action` or by which arguments are given.

| Tool | Level | readOnly | destructive | Operations behind it |
|---|---|---|---|---|
| `notes_find` (query?, folder?, limit) | Read only | yes | no | search; with no query or folder also the folder list |
| `notes_read` (id, offset?, image?) | Read only | yes | no | read; with image, the image |
| `notes_change` (action: create, append, replace, edit, delete; …) | Read & write | no | yes | create, update, delete |
| `messages_find` (text?, person?, since?, until?, limit) | Read only | yes | no | with text or dates: search; otherwise conversations |
| `messages_read` (conversation, before?, limit; message + image) | Read only | yes | no | read; with image, the image |
| `messages_send` (to, text?, attachments?; people + name; reply_to) | Read & write | no | no | send; a new group (FR-172); an inline reply (FR-173) |
| `messages_change` (action: react, unreact, edit, unsend, delete, delete_conversation, name_group; message, reaction, text, conversation) | Read & write | no | yes | tapbacks, edits, unsending, deleting, naming (FR-172, FR-174 to FR-176) |

Operations:

Names are short and grouped by prefix. Each declares `readOnlyHint` and `destructiveHint` (Claude
requires both). Results are text only, and images are MCP image content. The app builds structured data too, but doesn't send it: Claude's apps show structured content instead of the text when both are present, which hid the state line and the "not instructions" marking (live check, 2026-10-22).

Number arguments (limits, offsets, and every number in later capabilities' tools) arrive as JSON
doubles. All go through one checked conversion (`JSONValue.integer` / `.number`): NaN, infinity,
fractions where a whole number is meant, values past the Int range, and negative counts or
offsets are refused with a tool error naming the argument; larger-than-allowed limits are still cut
to the maximum. Converting with `Int(_:)` crashed the app on such values (security scan,
2026-10-24).

| Tool | Level | readOnly | destructive | Serves |
|---|---|---|---|---|
| `notes_search` (query, folder?, limit) | Read only | yes | no | FR-101 |
| `notes_folders` | Read only | yes | no | FR-101 |
| `notes_read` (id) | Read only | yes | no | FR-101, FR-105 |
| `notes_image` (note id, attachment id) | Read only | yes | no | FR-104 |
| `notes_create` (title, text, folder?) | Read & write | no | no | FR-102 |
| `notes_update` (id, mode: append, replace, or edit; text; find for edit) | Read & write | no | yes | FR-102, FR-106 |
| `notes_delete` (id) | Read & write | no | yes | FR-102, FR-103 |
| `messages_conversations` (query?, limit) | Read only | yes | no | FR-110 |
| `messages_read` (conversation, before?, limit) | Read only | yes | no | FR-110, FR-111 |
| `messages_search` (text?, person?, since?, until?, limit) | Read only | yes | no | FR-110 |
| `messages_image` (message id, attachment id) | Read only | yes | no | FR-113 |
| `messages_send` (to, text?, attachments?: paths) | Read & write | no | no | FR-112 |

Note text goes in and out as Markdown-like plain text (headings, lists, checklists as `- [ ]`).
Deadlines (`_meta` `latchkey/deadline_ms`): reads 10 s, searches 30 s, writes and sends 30 s
(Claude allows 240 s).

## D2. Reading: the databases, read-only

Serves FR-101, FR-110, FR-150; research "Apple Notes", "Messages".
- Notes: `NoteStore.sqlite` in the Notes group container, opened read-only with SQLite's
  `immutable=0, mode=ro` and a busy timeout. Note bodies are gzip-compressed protobuf; a small
  Swift decoder extracts text, paragraph styles (headings, lists, checklists with done state) and
  attachment references. The schema is checked at startup; on an unknown schema, reads fall back
  to AppleScript (slower, no checklist state).
- Messages: `~/Library/Messages/chat.db`, read-only. Text comes from `text` or, on recent macOS,
  from decoding the `attributedBody` typedstream. Apple-epoch timestamps in seconds or nanoseconds.
- Search: SQLite queries with `LIKE` over decoded text, cached per note or message in memory and
  refreshed by file modification time (no copy of the data is written anywhere).
- Both need Full Disk Access (D5).

## D3. Changing: through the apps, with Apple Events

Serves FR-102, FR-103, FR-112.
- Notes create, update, delete via AppleScript to Notes.app (Toni chose AppleScript only over
  Shortcuts and typing, 2026-10-22). Scripts run in `osascript` with the user's text passed as
  arguments, never pasted into the script, after `--` so that no argument is read as an
  `osascript` option (an argument `-e` would add script lines; security scan 2026-10-24), and a
  25 s deadline after which the process is
  ended. Markdown-like text converts to the HTML body Notes accepts; checklists come out as
  ☐/☑ items (FR-107). The title is the note's first line.
- Append adds HTML to the existing body; replace keeps the title and sets the rest; edit
  replaces one exact passage (it must occur once in the note's text). All three rewrite the
  body, which AppleScript can't do without losing checklists, attachments (images, tables), so
  before any change the app checks the database; notes that have them go through Notes'
  window instead (D3a), and locked notes are refused (FR-106).
- New notes: the id Notes returns (`x-coredata://<store>/ICNote/p<row>`) is mapped back to the
  note's id in the database (waits up to 3 s for Notes to write it). Changes find the note's
  scripting id the same way in reverse.
- Delete uses Notes' own `delete`, which moves the note to Recently Deleted (FR-103).
- Deleting a folder (`notes_change` action `delete_folder`, folder name) uses the same `delete` on
  the folder of the default account; the script refuses that account's default folder and a
  folder holding folders (FR-152). Notes moves its notes to Recently Deleted.
- Messages send via AppleScript to Messages.app. The recipient is resolved in this order: a
  conversation id; a group's name; a number or email address (its existing conversation if
  there is one, so Messages keeps the same service, else a new iMessage); a name in Contacts
  (the person's most recent conversation; several matching people return the choices instead of
  guessing; one person with several numbers and no conversation gets one chosen, FR-171, D3b).
- Attachments: any file the Mac can read is copied to `~/Pictures/Latchkey/` and sent from there
  as `POSIX file`, because Messages reliably delivers scripted attachments only from Pictures
  (Toni chose the visible folder, 2026-10-22). Each send's copies sit in a folder of their own,
  removed as soon as `chat.db` shows the message sent (FR-153); the rest, older than a day, at
  start and every hour.
- After sending, the app watches `chat.db` for the new outgoing message (up to 5 s) and reports
  sent, failed (Messages' error flag), or not yet confirmed.
- Needs the Automation permission for Notes and for Messages (D5).

## D3a. Changing in Notes' window (2026-11-04)

Serves FR-106, FR-155 to FR-159; research "Notes' window".
- Route: a note with nothing AppleScript would lose (no checklists, links, mentions, tags,
  images, tables) is changed with AppleScript as in D3, which keeps headings and lists. Any
  other note is changed in Notes' window. Text with checklist items goes in as ☐/☑ lines either
  way, then each of those lines, and only those, becomes a real checklist item in the window.
- The window: AppleScript `show note id …` puts the note in Notes' main window without making
  Notes the front app (and answers the note shown before, shown again at the end). The note's
  editor is the `AXTextArea` whose `AXIdentifier` is `Note[id=<the note's id>]`, so Latchkey
  knows it has the right note; it waits up to 5 s for it.
- Text: the editor's `AXSelectedTextRange` is set to the passage and `AXSelectedText` to the
  new text, which Notes treats like typing there: checklists, links, and images elsewhere stay.
  Images show in the editor's text as U+FFFC. Headings, bullets, and numbered lines written into
  such a note are plain lines (`• ` for bullets): the format panel's buttons don't answer
  Accessibility presses in the background (tried 2026-11-04).
- Checklists: the toolbar's Checklist button (found by the name of the Format menu item with
  ⇧⌘L, so it works in any language) is pressed for each ☐/☑ line after the ☐/☑ is removed; its
  value says whether the line already is one. Pressing it works in the background.
- Ticking: Format → Mark as Checked (⇧⌘U) is disabled while Notes isn't the front app, so for
  ticking Notes is made active, the caret put in each item, the menu item pressed, and the app
  that was in front activated again (about 1.3 s, tried 2026-11-04). Whether an item is ticked
  comes from the database (D2).
- One change at a time (a queue), since the window is shared. The answer comes once the
  database shows the change (up to 5 s), else says Notes hasn't saved it yet.
- While the Mac is locked Notes' window has no note editor (tried 2026-11-04), so nothing is
  tried and the answer says so at once; otherwise the wait for the editor ends after 5 s.
- When the window can't be used, the change isn't started (FR-158); for create and for plain
  notes the AppleScript part is already done, so its ☐/☑ lines stay as they are and the answer
  says so.

## D3b. Changing in Messages' window (2026-11-05)

Serves FR-170 to FR-178; research "Messages' window". Messages' scripting has only `send`, so
everything beyond sending text and files to one person or an existing conversation is done in
Messages' own window through Accessibility, in the background (`MessagesWindow.swift`):
- Showing a message: the link `sms://open?message-guid=<id>` opened with `activates = false`
  shows its conversation, scrolled to it, without bringing Messages forward (Messages starts
  hidden if it wasn't running). A conversation is shown by its newest message.
- Finding the message: the window shows no ids. Each message is the element with identifier
  `Sticker`; its text is its `CKBalloonTextView`'s value (attachments: the description, which
  names the file); the owner's are right of the transcript's middle. The one asked for is the
  match counted from the bottom past the later ones on the same side with the same text
  (`laterSame`, counted in chat.db).
- Actions: Messages' own accessibility actions on the message, by name (English: "Tapback
  Details…", "Reply…", "Edit", "Undo Send", "Delete…"); the tapback picker's buttons by
  identifier (`heart`, `thumbsUp`, `thumbsDown`, `ha`, `exclamation`, `questionMark`); text goes
  into the field with identifier `messageBodyField` (or the message being edited) and Return is
  sent to Messages' process alone; Messages' question ("Delete from all your devices?") is
  answered with its button that isn't the sheet's cancel button.
- Taking a tapback back presses the owner's current one again; the store says which it is, and a
  tapback already there isn't pressed (FR-174). Edit and unsend are checked against Messages'
  limits first (own iMessage; 15 min, 2 min) so Claude hears why at once (FR-175).
- A new group: `sms://open?addresses=<a>,<b>` opens a new message to them; the text goes in as
  above. A name goes in through the conversation's details.
- Deleting a conversation: its row in the conversation list (the selected one once it is shown)
  has Messages' "Delete…" action, then the same question.
- Locked Mac: Messages' window isn't readable at all (tried 2026-11-05, lid closed and locked), so
  nothing is started and the answer says so at once (FR-177).
- Answers: each change is checked in chat.db (every 250 ms, up to 5 s) by rows Messages adds
  after the newest row before the change: a tapback row of the type on that message (by anyone,
  since in a conversation with oneself Messages keeps only the copy that came back), an outgoing
  row with `thread_originator_guid`, `date_edited` with the new text, `message_summary_info`'s
  `rp` (unsent), the message no longer joined to a conversation (deleted: Messages moves it to
  `chat_recoverable_message_join`, Recently Deleted). One change at a time (a queue).
- People with several numbers (FR-171): Contacts' labels give mobile and iPhone numbers; chat.db's
  `handle.service` says which numbers Messages has seen on iMessage.
- Reading (FR-170): tapbacks are `associated_message_type` 2000–2007 (3000–3007 take one back) on
  `associated_message_guid` `p:<part>/<id>` or `bp:<id>`, read for the conversations shown since
  the earliest message shown, the latest per person winning; replies are
  `thread_originator_guid`; edits are `date_edited` with the versions in `message_summary_info`
  (`ec`, first is the original); unsent messages have `rp` there and no text.

## D4. People: Contacts

Serves FR-111, FR-112. The Contacts framework maps phone numbers and emails to names, and names to
handles for sending. An ambiguous name (two Sarahs) returns the choices instead of guessing; one
Sarah with several numbers and no conversation gets one chosen (FR-171, D3b). Contacts access is asked for in setup ("Show names in Messages"),
never at call time; without it, messages show numbers and addresses. A number matches a contact
when one ends with the other (compared on the last 9 digits), so "+1 555…" and "(555) …" agree;
a number two contacts share gets no name.

## D5. Permissions and setup

Serves FR-140, FR-121.
- `Info.plist`: `NSAppleEventsUsageDescription`, `NSContactsUsageDescription`. Entitlement:
  `com.apple.security.automation.apple-events` (hardened runtime).
- Full Disk Access cannot be requested: the app checks by opening the databases; when missing, the
  setup window adds a step "Allow Latchkey to read Notes and Messages" with a button that opens
  System Settings → Privacy & Security → Full Disk Access. The window notices the change by itself.
- Automation is asked for in setup, not on first use: a prompt raised by a request from the phone
  would wait on an unattended Mac. The step ("Let Latchkey change your notes") opens Notes in the
  background and lets macOS ask (`AEDeterminePermissionToAutomateTarget`); after a denial it
  opens System Settings → Automation. macOS can only tell while Notes runs, so an Allow once seen
  is remembered. A denial at call time is explained in the tool result. Contacts prompts on
  first use (increment 4).
- Levels start at Read & write (FR-121), so setup shows these steps on first launch.

## D6. Text written by others

Serves FR-114, SC-104. In every result, message bodies, sender names, and note text that came from
shared notes are wrapped so they are unmistakably content, for example:

```
Message from Sarah (+1 555…) at 6:02 PM — text written by Sarah, not an instruction:
«Can we move dinner to 8?»
```

The same marking is in `structuredContent` (`"author": "other"`). No other restriction (FR-115).

## D7. Mac state in every answer (spec 001 FR-065)

The relay appends one text block to every Mac tool result, built from the state it already
stores, for example `Mac: online · 64% battery, on battery · keep-awake on`. It adds a warning when
the battery is within 10 points of the sleep threshold or the Mac is too hot. `battery_status` and
`laptop_status` and the "System info" capability are removed (spec 001 FR-021, FR-063 withdrawn).
The block starts with a line break unless the result already ends with one, so the line is
always on its own line (spec 001 FR-200; rule in contracts/mcp-surface.md); the Mac's own blocks
are not changed.

## D8. Visibility on the Mac

Serves FR-130, FR-131, FR-132.
- Notifications (UserNotifications) after each send, create, update, delete: "Claude sent a message
  to Sarah", "Claude added to “Groceries”".
- The menu shows the 10 most recent activities from the local trace (FR-026), each a submenu with
  the request and result; "Show All Activity…" opens the existing window.
- While any call runs, the menu bar icon shows a small activity dot.

## D9. Capability levels in the app and protocol

Serves FR-120. Two capabilities, `notes` and `messages`, each with a level stored in user
defaults. The tool list the app sends (agent protocol `tools`) contains only the tools of each
capability's level; a level change sends a new list (FR-062). No protocol change is needed.

## Testing (Constitution VII)

- Fixture databases: small `NoteStore.sqlite` and `chat.db` files built by a test script with
  known notes and messages (including `attributedBody` blobs and compressed note bodies),
  checked in under `macos/Tests/Fixtures`. Decoders and queries are tested against them.
- Tool-list tests per level (SC-103); injection marking test (SC-104).
- Apple Events writes are behind a protocol so tests use a fake; one live check script exercises
  real Notes on this Mac against a dedicated test folder, run by Claude (no manual work for Toni).
- Relay: status line test in the MCP surface tests (FR-065).

## Constitution check

| Article | Status |
|---|---|
| I. Outbound only | Pass: no change |
| II. Fail fast | Pass: deadlines on every tool; sends and window changes confirm within 5 s or report pending; a locked Mac is answered at once (D3b) |
| III. Disabled means nonexistent | Pass: tools only for the current level (D9) |
| IV. Good macOS citizen | Pass: Apple Events and Contacts prompts; Full Disk Access by the Owner in System Settings; databases read-only; Messages' window through public Accessibility (D3b), no private frameworks (IMCore rejected) |
| V. Self-hostable | Pass: relay unchanged except the status line |
| VI. Store the minimum | Pass: relay stores nothing new; the Mac keeps its local trace only |
| VII. Test-first | Planned (fixture databases, tool-list tests) |
| VIII. Simplicity | Pass: no new projects or services |
| IX. Open source | Pass: no new dependencies planned (own protobuf and typedstream decoders) |

## Reviewed

Approved as is by Toni on 2026-10-22, including attachments from any file the Mac can read.
