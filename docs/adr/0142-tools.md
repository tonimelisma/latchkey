# 0142. Tools

- Status: accepted
- Date: 2026-11-03
- Alias: plan 012 D5 (`specs/012-whatsapp/plan.md`, "D5. Tools")

## Context and problem

Decision D5 of spec 012's plan (WhatsApp); requirements in
[requirements/whatsapp.md](../requirements/whatsapp.md). Requirement IDs it cites: FR-1232, FR-1240, FR-1244, FR-1222.
The design it belongs to: [design/whatsapp.md](../design/whatsapp.md).

## Decision


Serves FR-1212 to FR-1232. Names follow Messages (spec 002).

- `whatsapp_find` (read): with nothing, the chats newest first (name, group or person, unread
  count, last message time); with `text`, `chat`, `since`, `until`: messages; `person`, `unread`,
  `limit`, `offset`.
- `whatsapp_read` (read): one chat's messages by `chat` (name, number, or id), `limit`, `before`.
- `whatsapp_send` (write): `to`, `text`, `files`, `reply_to` (a message id, FR-1241). One match
  is required: several give the candidates and nothing is sent (FR-1213). Through the tab (D1),
  else WhatsApp for Mac's window (D3b).
- `whatsapp_change` (write, 2026-11-05): `chat`, `message` (its id), `action` react | unreact |
  delete, `emoji`, `everyone` (FR-1242, FR-1243). Through the tab, else WhatsApp for Mac's window.
  Options weighed for the shape: separate tools per action (more names for Claude to choose
  from), or one change tool like `notes_change` and `mail_change` (chosen: the pattern the other
  capabilities use).
- Message ids (FR-1240): WhatsApp's own key for a message, `id.id` in WhatsApp Web and
  `ZSTANZAID` in WhatsApp for Mac's database (the same string, checked 2026-11-05), shown as
  `msg <id>` on every message line. Options weighed: the database's row number (only one path
  knows it), WhatsApp Web's full id (`true_<chat>_<key>_out`, long, Web only), the stanza key
  (both paths; chosen).
- "me" (FR-1244): WhatsApp Web's own idea of who is logged in (`WAWebUserPrefsMeUser`); in the
  database the one account with a country code in `LID.sqlite` (`ZWAZACCOUNT`), matched on the
  chat's id only, never on the name You (security review 2026-11-05).
- Older history (FR-1248): while reading through the tab, when it holds fewer messages than asked
  for, the rest come from WhatsApp for Mac's database (messages before the oldest one shown,
  found by chat id: `@c.us` is `@s.whatsapp.net` there, or the privacy id), marked as such.
- Reading source (FR-1222): the database while WhatsApp for Mac runs; else the tab when connected;
  else the database, saying how old its newest message is; else an answer saying neither is there.
  A chat's time and preview come from its last message (`ZLASTMESSAGE`): `ZLASTMESSAGEDATE` is a
  sort key WhatsApp moves thousands of years ahead for a pinned chat, and `ZLASTMESSAGETEXT` is
  encoded. Senders known only by privacy id (`…@lid`) get their names from WhatsApp's copy of the
  address book, `ContactsV2.sqlite`.
- After a relink WhatsApp for Mac files most person chats by privacy id (`…@lid`; 47 of 60 on
  2026-11-04). The address book's `ZLID` and `ZWHATSAPPID` give number ↔ privacy id, so a phone
  number finds such a chat, the window (D3) gets the number for one, and its confirmation looks
  under both ids (the confirmation was the withdrawn window's, D3).
- Files are checked for size and kind before they are read (security review 2026-11-03); at most
  64 MB per call; photos (`image/*`) go as photos, anything else as documents.
- Settings, WhatsApp section: one line on what WhatsApp needs on the Mac and the warning
  (FR-1232).

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/WhatsAppStoreTests.swift`
- `macos/Tests/WhatsAppToolsTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
