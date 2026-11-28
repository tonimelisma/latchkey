# 0033. Changing: through the apps, with Apple Events

- Status: accepted
- Date: 2026-10-21
- Alias: plan 002 D3 (`specs/002-notes-messages/plan.md`, "D3. Changing: through the apps, with Apple Events")

## Context and problem

Decision D3 of spec 002's plan (Notes and Messages); requirements in
[requirements/notes-messages.md](../requirements/notes-messages.md). Requirement IDs it cites: FR-102, FR-103, FR-112, FR-107, FR-106, FR-152, FR-171, FR-153.
The design it belongs to: [design/notes-messages.md](../design/notes-messages.md).

## Decision


Serves FR-102, FR-103, FR-112.
- Notes create, update, delete via AppleScript to Notes.app (the maintainer chose AppleScript only over
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
  (the maintainer chose the visible folder, 2026-10-22). Each send's copies sit in a folder of their own,
  removed as soon as `chat.db` shows the message sent (FR-153); the rest, older than a day, at
  start and every hour.
- After sending, the app watches `chat.db` for the new outgoing message (up to 5 s) and reports
  sent, failed (Messages' error flag), or not yet confirmed.
- Needs the Automation permission for Notes and for Messages (D5).

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/MessagesSendTests.swift`
- `macos/Tests/NotesWriteTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
