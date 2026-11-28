# 0140. WhatsApp for Mac's window again, as the fallback (2026-11-05)

- Status: accepted
- Date: 2026-11-05
- Alias: plan 012 D3b (`specs/012-whatsapp/plan.md`, "D3b. WhatsApp for Mac's window again, as the fallback (2026-11-05)")

## Context and problem

Decision D3b of spec 012's plan (WhatsApp); requirements in
[requirements/whatsapp.md](../requirements/whatsapp.md). Requirement IDs it cites: none current.
The design it belongs to: [design/whatsapp.md](../design/whatsapp.md).

## Decision


Serves FR-1245, FR-1246, FR-1247, FR-1249. Reverses D3's withdrawal: the maintainer asked for everything
missing, and a fallback that works only unlocked still beats none when Safari can't be used
(working functionality outranks the 2026-11-04 decision). Research: "2026-11-05" in research.md.

- Used only when the tab can't be used (no tab and none could be opened, Safari not answering,
  logged out, not connected, WhatsApp Web changed) and nothing went through it (FR-1216), with
  WhatsApp for Mac running and its database readable. The answer says why Safari wasn't used.
- Locked (FR-1249): WhatsApp for Mac shows Accessibility nothing but its menu bar; the answer
  says so at once. Nothing is tried.
- Everything through Accessibility, as the computer tools do (`AXPress`, `AXShowMenu`,
  `AXScrollToVisible`, `AXScrollUp/DownByPage`), with WhatsApp found by its bundle id (its name
  starts with an invisible mark). WhatsApp stays behind for opening chats and for text to a person
  or the Owner's own chat; a message's menu (React, Reply, Delete), typing, and files bring it to
  the front for a few seconds (FR-1250).
- Opening the chat with certainty (FR-1246, security review 2026-11-05): a person with a known
  number, and the Owner's own chat with the Owner's number, through WhatsApp's own link
  `whatsapp://send?phone=<digits>` opened without activating; the header must then name that
  chat ("You" for the Owner's own). A group, or a person without a known number, by its row in
  the chat list, only when no other chat in the database has that name and the whole list
  (scrolled a page at a time) shows exactly one row with it.
- The message (FR-1246): looked for only in the open chat's messages, by side ("Your …" only for
  the Owner's own), words or file name, date and time ("November 4, at 21:22"; today's carry the
  time alone), scrolling up for older ones; refused when it has no words or file name, when more
  than one bubble matches, or when the database has another message of that chat with the same
  side, words, and minute.
- Delete: the message menu's Delete, which selects it; the selection bar's Delete; then "Delete
  for me" or "Delete for everyone" in WhatsApp's own dialog. React: the message menu's React,
  then the emoji. Reply: the message menu's Reply before the text.
- Text and files. Options weighed, least intrusive first (all tried live 2026-11-05):
  1. Background only: keys sent to WhatsApp's process alone, the box's `AXValue`, and
     `AXSelectedText` don't put text in (rejected).
  2. `whatsapp://send?phone=…&text=…` opened without activating, then Send pressed: all in the
     background (chosen for text to a person with a number and to the Owner's own chat).
  3. Drag files: needs the real pointer (rejected). Edit → Paste: disabled even in front (rejected).
  4. WhatsApp briefly in front (as Notes' tick, spec 002 D3a): text typed through the session's
     event stream, files by Command-V there (each opens WhatsApp's preview, sent with its Send; the
     text follows as its own message), the Owner's clipboard put back, their app brought back.
     Chosen for groups, people without a known number, files, and replies (Reply's menu brings
     WhatsApp forward anyway).
- WhatsApp in front only safely (security review 2026-11-05): not when the keyboard or pointer was
  used in the last 3 seconds; before every keystroke, paste, and press, WhatsApp must still be in
  front, the chat still this one, and no input newer than Latchkey's own; before Send the box must
  hold exactly the text. Otherwise nothing is sent and the box is emptied.
- Opening: Chat → Close Chat first, so the header can only name the chat this call opens; the
  Owner's own chat only when no chat in the lists (Archived too) is named You; a row only when it
  is the only one with that name in the lists and in the database.
- React: WhatsApp's tray of twelve (the picker for other emoji isn't used; the answer lists the
  twelve); unreact presses the Owner's selected one.
- Confirmation in WhatsApp for Mac's database (FR-1247), by the message's id: a deletion when the
  row is gone (for me) or type 14 (for everyone); a reaction when that message's stamp (its row
  version and its receipts, where reactions are kept) changed; a send when a new message of the
  Owner's with that text is in that chat. Otherwise the answer says it may or may not have
  happened (FR-1216), never retried.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
