# 0035. Changing in Messages' window (2026-11-05)

- Status: accepted
- Date: 2026-11-05
- Alias: plan 002 D3b (`specs/002-notes-messages/plan.md`, "D3b. Changing in Messages' window (2026-11-05)")

## Context and problem

Decision D3b of spec 002's plan (Notes and Messages); requirements in
[requirements/notes-messages.md](../requirements/notes-messages.md). Requirement IDs it cites: FR-170, FR-171.
The design it belongs to: [design/notes-messages.md](../design/notes-messages.md).

## Decision


Serves FR-170 to FR-178; research "Messages' window". Messages' scripting has only `send`, so
everything beyond sending text and files to one person or an existing conversation is done in
Messages' own window through Accessibility, in the background (MessagesWindow.swift):
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
  above. A name would go in through the conversation's details; until that field is found
  (research), naming answers plainly that it can't be done yet and the group stays unnamed.
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

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/MessagesFixture.swift`
- `macos/Tests/MessagesSendTests.swift`
- `macos/Tests/MessagesTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
