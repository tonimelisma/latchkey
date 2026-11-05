# Spec 012: WhatsApp — WHAT and WHY

Status: Rebuilt 2026-11-04 without a linked device of Latchkey's own (Toni): reading from
WhatsApp for Mac's database or the Owner's WhatsApp Web tab in Safari, sending through that tab,
else through WhatsApp for Mac's window. First built in 0.8.101 (2026-11-03) with Latchkey's own
linked device; on 2026-11-04, after two days of linking that device and test devices by code,
WhatsApp logged out every linked device of Toni's account (the phone stayed logged in).
Scope: Claude reads, searches, and sends the Owner's WhatsApp messages from any Claude app,
through the Mac, including while the Mac is locked where the Mac allows it.
Out of scope: calls, status updates, communities and channels, changing WhatsApp settings.

Research, with the tests run on Toni's Mac: `research.md`.

## Problem

Many people's family and friends are on WhatsApp, not iMessage. "Tell my wife I'm on my way",
"what did the group say about Saturday?" need WhatsApp, and the Owner is usually away from the
Mac when they ask: the Mac is at home, locked, often with the lid closed. Queueing a message until
the next unlock is useless for messaging.

## User stories

### US1 (P1): Send a WhatsApp message from anywhere, now
As an Owner, I ask Claude to send a WhatsApp message, and it goes out right away.

1. Given WhatsApp is set to Read & write and WhatsApp Web is open in Safari, when I say
   "WhatsApp my wife I'm on my way", then the message is sent within a minute and Claude says it
   was sent, whether the Mac is unlocked or locked (where Safari answers while locked).
2. Given the Safari tab can't be used and the Mac is unlocked, then the text goes through
   WhatsApp for Mac's window, which comes to the front for a moment.
3. Given the message can't be sent (no tab, Mac locked and no tab, Mac offline), then Claude says
   so at once, in plain words, and nothing is sent later without being asked again.

### US2 (P1): Read and search my WhatsApp
1. Given WhatsApp is Read only or Read & write, when I ask "what did the family group say about
   Saturday?", then Claude finds the messages and answers, with names rather than numbers.
2. Given I ask for my unread WhatsApp messages, then Claude lists them by chat.

### US3 (P1): Nothing new to link
1. Latchkey uses the WhatsApp I already linked myself (WhatsApp for Mac, WhatsApp Web in Safari)
   and never links a device of its own.
2. Given WhatsApp is Off, then no WhatsApp tool exists (Constitution III).

### US4 (P1): See what Claude sent
1. Given Claude sent a WhatsApp message, then my Mac shows a notification and the menu bar
   activity lists it (as for Messages, spec 002).

## Requirements

### Where WhatsApp is reached

- **FR-1201** Withdrawn 2026-11-04 (Latchkey's own linked device; see FR-1206).
- **FR-1202** Withdrawn 2026-11-04 (staying linked: Latchkey links nothing).
- **FR-1203** Withdrawn 2026-11-04 (logging Latchkey's device out; see FR-1207).
- **FR-1204** Withdrawn 2026-11-04 (being unlinked by WhatsApp).
- **FR-1205** Withdrawn 2026-11-04 (link codes).
- **FR-1206** The system shall reach WhatsApp only through what the Owner linked themself:
  WhatsApp for Mac and WhatsApp Web in Safari; it shall never link a device of its own nor ask
  WhatsApp for a link code (Toni, 2026-11-04).
- **FR-1207** When a version without its own device first starts on a Mac where the earlier one
  stored a device, the system shall delete what that device stored.
- **FR-1208** The system shall not reload, navigate, or close the Owner's WhatsApp Web tab, nor
  bring Safari to the front.

### Sending

- **FR-1210** Withdrawn 2026-11-04 (sending through Latchkey's own device; see FR-1215).
- **FR-1211** Withdrawn 2026-11-04 (no window ever; see FR-1215).
- **FR-1212** When the system can't send, it shall answer within the call's deadline (spec 001
  FR-011) saying why, and shall not send the message later on its own.
- **FR-1213** When the recipient matches more than one chat or contact, the system shall not send,
  and shall answer with the candidates so Claude can ask the Owner.
- **FR-1214** Through the Safari tab, the system shall send to a person or a group, and shall send
  photos and files from the Mac as attachments, as well as text (Toni, 2026-11-02).
- **FR-1215** When Claude asks to send, the system shall send through the Owner's WhatsApp Web
  tab in Safari, without taking focus; when that tab can't be used (none open, not connected,
  Safari not answering), and only then, it shall send through WhatsApp for Mac's window: text to
  a person, with the Mac unlocked, the window coming to the front for a moment and the app the
  Owner was in coming back after (Toni, 2026-11-04: Safari tab first, the window as fallback).
- **FR-1216** When a send through the Safari tab may have gone (WhatsApp hasn't confirmed it), the
  system shall not try the window too, and shall say to check before sending again.

### Reading

- **FR-1220** When Claude asks for chats or messages, the system shall find them by person, chat,
  words, date, and unread, and show names from the Owner's contacts and WhatsApp's own names
  rather than numbers.
- **FR-1221** Withdrawn 2026-11-04 (reading through Latchkey's own device; see FR-1222).
- **FR-1222** While WhatsApp for Mac is running, the system shall read from its database;
  otherwise from the Owner's WhatsApp Web tab in Safari; otherwise from the database, saying how
  old its newest message is (Toni, 2026-11-04).

### Permissions and visibility

- **FR-1230** WhatsApp shall have the same three settings as Messages: Off, Read only, Read &
  write; Read only shall offer no sending tool (spec 002 pattern, Constitution III).
- **FR-1231** When Claude sends a WhatsApp message, the system shall show a notification and list
  it in the menu bar activity, as for Messages.
- **FR-1232** Settings shall tell the Owner in one plain sentence that WhatsApp's terms forbid
  automated messaging and that a ban, though unlikely for personal use, is possible (Toni,
  2026-11-02), and what WhatsApp needs on the Mac (Safari's tab, or WhatsApp for Mac).

## Success criteria

- **SC-1201** With the Mac locked and the lid closed, "WhatsApp <person> <text>" from Claude on a
  phone sends the message through the Safari tab, and the person receives it, within 60 s; or,
  where Safari doesn't answer while locked, Claude says so at once.
- **SC-1202** Withdrawn 2026-11-04 (staying linked for 24 hours).
- **SC-1203** While the Owner types in another app, a send through the Safari tab causes no focus
  change, window, or pointer movement (checked with `focus.log` from the screen-state checks).

## Open questions

None.
