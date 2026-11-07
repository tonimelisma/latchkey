# Spec 008: Mail — WHAT and WHY

**Withdrawn 2026-11-07 (Toni: "remove all mail related functionality. that's better done via APIs"):** the whole Mail capability (every requirement here). Latchkey has no Mail tools; this spec stays as the record.

Status: Draft for Toni's review (2026-10-29). No tasks or code before the review.
Scope: the Owner's mail in Apple Mail on the Mac, in every account Mail has: finding and reading
messages, organising them, drafting, replying, forwarding, and sending. This supersedes the
2026-10-22 roadmap decision that there would be no Mail tool (Toni, 2026-10-29: "add mail").
Out of scope: Mail rules, mail merge (one message to many people), creating, renaming, or
deleting mailboxes (Toni, 2026-10-29); permanently erasing mail or emptying the Trash; mail apps
other than Apple Mail.

## Problem

The Owner's mail is on the Mac in Apple Mail: an Exchange account, two Gmail accounts, iCloud,
and On My Mac, about 100,000 messages. From a phone, Claude can't find "the lease renewal from
my landlord", tell what's new in the inbox, answer a message, or file it away.

## User stories

### US1 (P1): Find and read my mail
1. Given Mail is Read only or more, when I ask "anything new from my landlord?", then Claude
   finds the messages by sender, subject, date, mailbox, read state, or flag, newest first, and
   says which are unread.
2. Given a message, when I ask what it says, then Claude reads it, its attachments' names, and
   can look at an image or document attached.
3. Given I ask about something only in the text of a message, then Claude searches the text,
   newest first, and tells me how far back it got.
4. Given Claude only looks something up in a message for its own work, then the message stays
   unread; given Claude shows or summarises a message to me, then it marks it read.

### US2 (P1): Organise my mail
1. Given Read & write, when I ask Claude to file a message, flag it, mark it read or unread, or
   mark it as junk, then it does.
2. Given I ask Claude to delete a message, then it goes to that account's Trash.

### US3 (P1): Write and send
1. Given Read & write, when I ask Claude to reply, then the reply goes from the right account,
   in the conversation, with the original quoted as Mail does.
2. Given I ask Claude to write a new message or forward one, with or without attachments, then
   it is sent, and the sent copy is in that account's Sent mailbox.
3. Given I ask Claude only for a draft, then the draft is in Mail's Drafts for me to send.

## Requirements

### Finding and reading
- **FR-801** While Mail is Read only or Read & write, Claude shall be able to list Mail's
  accounts and mailboxes with their unread counts, and find messages in every account by
  sender, recipient, subject, date, mailbox, account, read state, flag, and whether they have
  attachments, newest first, a page at a time. Each result shall give the account, the
  mailbox, the sender, the subject, the date, and whether it is unread, flagged, or has
  attachments.
- **FR-802** When Claude searches the text of messages, Latchkey shall look newest first within a
  time limit, and the answer shall say how far back it looked and how to look further. Latchkey
  shall keep no copy of the Owner's mail for searching (Toni, 2026-10-29).
- **FR-803** Claude shall be able to read a message: its sender, recipients, date, subject, text
  (mail written as HTML as plain text, never loading anything from the internet), and its
  attachments' names, types, and sizes; and the other messages of its conversation.
- **FR-804** Claude shall be able to look at an attachment: an image as an image, a PDF or
  document as its text, other files by name and size only. An attachment not yet downloaded
  shall be downloaded first, or the answer shall say it isn't on the Mac.
- **FR-805** Reading a message shall not mark it read. Claude shall be able to mark it read in
  the same request, and shall be told to do so when the Owner will see what the message says
  (Claude shows or summarises it to them), and not when Claude only looks something up for its
  own work (Toni, 2026-10-29).
- **FR-806** Text written by others (senders' names, addresses, subjects, message text,
  attachment names) shall be marked in every result as written by others, not instructions (as
  spec 002 FR-114).
- **FR-807** A message that is on the mail server only, or only partly on the Mac, shall be
  found with what the Mac knows of it, and the answer shall say its text isn't on the Mac rather
  than show it as empty.

### Organising
- **FR-810** While Mail is Read & write, Claude shall be able to mark messages read or unread,
  flag or unflag them, move them to another mailbox of the same account, and mark them as junk
  or not junk, one or several at a time.
- **FR-811** Deleting a message shall move it to its account's Trash, never erase it (Toni,
  2026-10-29).

### Writing and sending
- **FR-820** While Mail is Read & write, Claude shall be able to send a new message, a reply (to
  the sender or to all), or a forward, with text and attachments of any file the Mac can read,
  from any of Mail's accounts. Sending shall be a tool of its own, apart from organising and
  drafts, so Claude's apps can ask about sending specifically (Toni, 2026-10-29).
- **FR-821** Claude shall be able to save a new message, a reply, or a forward as a draft in the
  account's Drafts mailbox instead of sending it.
- **FR-822** A reply or forward shall go from the account the original message came to; a new
  message from the account Claude names, or Mail's default. A sending address that isn't one of
  Mail's accounts shall be refused.
- **FR-823** When a message is sent, Latchkey shall confirm it is in the account's Sent mailbox,
  with its attachments, before answering that it was sent. A send whose outcome Latchkey can't
  confirm in time shall be answered as unconfirmed, with how to check, and never sent again by
  Latchkey.
- **FR-824** Latchkey shall not add its own confirmations or limits to sending (as spec 002
  FR-115); Claude's apps handle approvals.
- **FR-835** While the Mac is locked, a reply or forward with attachments shall answer that the
  Mac is locked, and that the message can be sent without the file now or queued to go out when
  the Mac is next unlocked (FR-836), so Claude can decide with the Owner (Toni, 2026-11-02;
  narrowed 2026-11-05 from every send and draft, which now work while locked: FR-841).
- **FR-836** While Mail is Read & write, Claude shall be able, in a tool of its own, to queue a
  new message, a reply, or a forward (the same inputs as sending), list what is queued, and
  cancel a queued message (Toni, 2026-11-02: "separate tool for queued emails").
- **FR-837** When the Mac is next unlocked, Latchkey shall send each queued message, oldest
  first, the same way as sending (FR-820 to FR-823), tell the Owner in a notification and the
  activity log whether each was sent, and remove it from the queue. A queued message is kept only
  on the Mac, readable only by the Owner's account, until it is sent, given up on (FR-838), or
  cancelled.
- **FR-838** When a queued message's try sent nothing, Latchkey shall keep it queued and try
  again five minutes later while the Mac stays unlocked, and at the next unlock; after three
  such tries, or when a try may have sent it, it shall drop it. The Owner's notification says,
  in plain sentences, what happened and whether it will be tried again; the queue's list shows
  the last failure (Toni, 2026-11-02: a frozen Mail failed the first queued message, and the
  queue lost it).
- **FR-839** When Mail doesn't answer Latchkey's scripting in time, Latchkey shall look for an
  alert Mail is showing in a window of its own; when the alert has a single button, Latchkey
  shall press it and tell Claude and the Owner (in a notification) what it said, so Claude can
  try again; otherwise it shall tell Claude what the alert says, its buttons, and that someone
  at the Mac needs to answer it. Latchkey never starts Mail to look (Toni, 2026-11-02, "if
  exchange doesn't accept our messages, that's our issue": an alert that Mail couldn't save a
  sent copy, with the lid closed, held Mail until someone pressed OK).
- **FR-840** (Since 2026-11-05 this applies only to messages with attachments, FR-842.) While the
  Owner uses the Mac, writing an email shall not bring Mail to the front:
  the message (new, reply, reply all, forward) is made by Mail's scripting with its window
  behind the Owner's apps and moved off-screen, files are attached by scripting, the text is
  typed into it with Mail behind, and it is sent or saved by scripting (Toni, 2026-11-02: "make
  the mail less intrusive"; checked live: nothing came forward, the text arrived unquoted, the
  file attached). A reply's or forward's files are pasted, since attaching by scripting erases
  the quoted original (tried 2026-11-03). Only then, or when scripting can't make the message,
  does Mail come forward, for the moments it
  must (opening, pasting files, Send or saving), each after a pause in the Owner's typing. Keys go in only while Mail's focus is in the field being
  filled; without a pause in the Owner's typing within 30 s nothing is sent; the Owner's own Mail
  window stays the one their keys go to; and the fields are read again in front, just before
  Send (security review 2026-11-02).

- **FR-841** When Claude sends, replies, forwards, or saves a draft without attachments, Latchkey
  shall write it through Mail's scripting with no window, whether the Mac is unlocked, locked, or
  its lid closed, and without Accessibility; the text shall arrive as ordinary text, not marked as
  quoted, and a reply's or forward's text above Mail's quote of the original (2026-11-05: Toni
  mostly uses Claude from his phone with the Mac locked or the lid closed).
- **FR-842** While Mail's window can be used, a message with attachments shall be written in Mail's
  window (FR-840). While it can't (the Mac locked, or no Accessibility), a new message with
  attachments shall be written through Mail's scripting, and the answer shall say the files are
  above the text.
- **FR-843** While Mail's window can't be used, a reply or forward with attachments shall not be
  sent; the answer shall say why and that it can go without the file now, the file can go in a
  new message, or it can be queued (FR-836). Mail's scripting can add a file to a reply or forward
  only by dropping its quoted original (tried 2026-11-05).
- **FR-844** Before a message written through Mail's scripting is sent or saved, Latchkey shall
  check its subject, its From, and every recipient (as addresses) as in Mail's window (FR-840,
  plan D6 step 5), a reply's or forward's own recipients against the original; on any difference
  it shall close the message unsent.
- **FR-845** Anything Latchkey adds to Mail's settings to write a message shall be removed before
  the message is sent or saved, also when writing fails, and anything left by a write that was cut
  off shall be removed by the next write.

### Level, visibility, permissions
- **FR-830** Mail shall have the levels Off, Read only, Read & write, where Read & write includes
  sending, and start at Read & write on first launch and on updating to this version (Toni,
  2026-10-29). Only tools allowed by the level exist for Claude (Constitution III).
- **FR-831** Claude shall reach every account and mailbox in Mail (Toni, 2026-10-29).
- **FR-832** When Claude sends, saves a draft, moves, deletes, or marks messages, the Mac shall
  show a notification naming the action and the message, and the activity shall list it (as
  spec 002 FR-130, FR-131).
- **FR-833** When Mail's data can't be read (Full Disk Access missing) or Mail can't be told what
  to do (Automation for Mail missing), the setup window shall show the step, and the tools
  shall say plainly what to turn on.
- **FR-834** When Mail's data has a layout Latchkey doesn't know (after a macOS update), Latchkey
  shall say so plainly instead of answering wrong or incomplete.

## Success criteria

- **SC-801** From the phone, "anything new from my landlord?" is answered in under 2 seconds on
  a Mac with 100,000 messages.
- **SC-802** A reply Claude sends is in the conversation and in Sent, from the right account, and
  shows as an ordinary reply in a phone's mail app.
- **SC-803** A deleted message is in the account's Trash.
- **SC-804** With Mail Off or Read only, the excluded tools never appear (test suite).

## Edge cases

- Gmail: one message appears under several labels (Inbox, a label, All Mail); found once, and
  moving between labels relabels it.
- Exchange folders and iCloud; several mailboxes with the same name in different accounts.
- Mail not running: Latchkey starts it for changes and sending; reading doesn't need it.
- Very large messages and attachments; messages in other languages and encodings; mail with
  only HTML; encrypted (S/MIME) mail.
- A message deleted or moved between finding it and acting on it.
- Text written by Claude through Mail's scripting arriving in other mail apps marked as quoted
  (reported since Mail 16): checked live before building sending; if it happens on macOS 27,
  Toni chooses how to send. The live check of 2026-10-29 shows it happens on macOS 27; Toni chose
  (2026-10-30) to write every message, reply, forward, and draft in Mail's own compose window,
  so it arrives as ordinary mail, and, when that isn't possible (the Mac locked, no
  Accessibility), to refuse plainly instead of sending scripted text. That window works with the
  lid closed and the display off as long as the Mac isn't locked (live check 2026-11-01), so only
  the lock stops sending (Toni, 2026-11-01). Reversed for text without attachments (2026-11-05, Toni's "add everything
  missing"): text put in as a Mail signature for a moment, instead of as the message's content,
  arrives unquoted (checked live), so such messages are written through Mail's scripting in every
  screen state (FR-841); the window is kept for attachments while it can be used (FR-842).
- Mail showing a name instead of an address in the To field (the account's full name for the
  Owner's own address, or a name Mail remembers): the account's full name counts for its own
  addresses (2026-11-01).
