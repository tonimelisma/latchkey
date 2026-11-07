# Spec 012: WhatsApp — WHAT and WHY

**Withdrawn 2026-11-07 (Toni: unreliable, and driving an app the user may be using disturbs them, Constitution IV):** sending and changing messages (whatsapp_send, whatsapp_change; WhatsApp Web in Safari and WhatsApp for Mac's window: FR-1208, FR-1213 to FR-1220, FR-1245 to FR-1250 and every sending requirement) and reading through WhatsApp Web. WhatsApp is read and searched from WhatsApp for Mac's database only.

Status: Rebuilt 2026-11-04 without a linked device of Latchkey's own (Toni): reading from
WhatsApp for Mac's database or the Owner's WhatsApp Web tab in Safari, sending only through that
tab, opened by Latchkey when none is (Toni, 2026-11-04: the window fallback worked only unlocked). First built in 0.8.101 (2026-11-03) with Latchkey's own
linked device; on 2026-11-04, after two days of linking that device and test devices by code,
WhatsApp logged out every linked device of Toni's account (the phone stayed logged in).
Extended 2026-11-05 (Toni: "add everything missing"): replies, reactions, and deleting on both
paths; the Owner's own chat as "me"; older history from WhatsApp for Mac's database while reading
through Safari; and WhatsApp for Mac's window again, as the fallback when the Safari tab can't be
used (reverses FR-1215's "only through Safari").
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
2. Given no WhatsApp tab is open in Safari, then Latchkey opens one behind the others, with
   Safari's own WhatsApp login, and sends through it.
3. Given the message can't be sent (logged out in Safari, Safari not answering, Mac offline), then Claude says
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
  bring Safari to the front; when no WhatsApp Web tab is open, it shall open one at the end of
  Safari's front window without selecting it (a window when Safari has none), and use it (Toni,
  2026-11-04).

### Sending

- **FR-1210** Withdrawn 2026-11-04 (sending through Latchkey's own device; see FR-1215).
- **FR-1211** Withdrawn 2026-11-04 (no window ever; see FR-1215).
- **FR-1212** When the system can't send, it shall answer within the call's deadline (spec 001
  FR-011) saying why, and shall not send the message later on its own.
- **FR-1213** When the recipient matches more than one chat or contact, the system shall not send,
  and shall answer with the candidates so Claude can ask the Owner.
- **FR-1214** Through the Safari tab, the system shall send to a person or a group, and shall send
  photos and files from the Mac as attachments, as well as text (Toni, 2026-11-02).
- **FR-1215** Withdrawn 2026-11-05 (sending only through WhatsApp Web in Safari; WhatsApp for
  Mac's window is the fallback again, FR-1245).
- **FR-1216** When a send may have gone (WhatsApp hasn't confirmed it), the system shall not send
  it again, and shall say to check before sending again.

### Reading

- **FR-1220** When Claude asks for chats or messages, the system shall find them by person, chat,
  words, date, and unread, and show names from the Owner's contacts and WhatsApp's own names
  rather than numbers.
- **FR-1221** Withdrawn 2026-11-04 (reading through Latchkey's own device; see FR-1222).
- **FR-1222** While WhatsApp for Mac is running, the system shall read from its database;
  otherwise from the Owner's WhatsApp Web tab in Safari; otherwise from the database, saying how
  old its newest message is (Toni, 2026-11-04).

- **FR-1248** While the system reads through the Safari tab and WhatsApp for Mac's database is
  readable, when the tab holds fewer messages than asked for, the system shall add the older
  messages from the database, saying which ones come from it and that it may be out of date.

### Replies, reactions, and deleting (2026-11-05)

- **FR-1240** The system shall show each message with WhatsApp's own id for it, the same through
  the Safari tab and WhatsApp for Mac's database, so Claude can reply to, react to, or delete it.
- **FR-1241** When Claude sends with a message's id to reply to, the system shall send the text or
  files as a reply quoting that message, and say whether WhatsApp shows it as a reply; when that
  message isn't in the chat, the system shall send nothing.
- **FR-1242** When Claude asks to react to a message, the system shall put that emoji on it as the
  Owner's reaction (replacing an earlier one), and, when asked to unreact, take the Owner's
  reaction off.
- **FR-1243** When Claude asks to delete a message, the system shall delete it for the Owner only,
  or, when asked for everyone, for everyone in the chat: only the Owner's own messages and only
  while WhatsApp allows it; otherwise it shall do nothing and say WhatsApp's reason.
- **FR-1244** When Claude names the chat "me", the system shall use the Owner's own chat
  ("Message yourself"), found by the Owner's own account, never by a chat's name; when that
  account isn't known, it shall say no chat matches.

### WhatsApp for Mac when the Safari tab can't be used (2026-11-05)

- **FR-1245** When the Safari tab can't be used before anything went through it, and WhatsApp for
  Mac runs and the Mac is unlocked, the system shall send through WhatsApp for Mac's window, to a
  person (with or without a known number) or a group, text, files, or both, and as a reply,
  confirmed in WhatsApp for Mac's database; and say in the answer why Safari wasn't used.
- **FR-1246** The system shall act in WhatsApp for Mac's window only on a chat it opened with
  certainty (a person by their number through WhatsApp's own link, the Owner's own chat by the
  Owner's number, anything else only by a name no other chat has) and only on a message whose
  side, words or file name, date, and time no other message of that chat shares; otherwise it
  shall do nothing and say why.
- **FR-1247** When the Safari tab can't be used, the system shall react, unreact, and delete
  through WhatsApp for Mac's window, and count it done only when WhatsApp for Mac's database shows
  that very message (by its id) changed.
- **FR-1250** When WhatsApp for Mac must come to the front (its message menu, typing, files), the
  system shall not do it while the Owner used the keyboard or pointer in the last 3 seconds; shall
  stop without sending when the Owner does, another app comes to the front, the chat changes, or
  the message box doesn't hold exactly the text; shall put back the Owner's clipboard; and shall
  bring back the app that was in front.
- **FR-1249** While the Mac is locked and the Safari tab can't be used, the system shall answer at
  once that WhatsApp for Mac's window can't be used while the Mac is locked, and do nothing.

### Permissions and visibility

- **FR-1230** WhatsApp shall have the same three settings as Messages: Off, Read only, Read &
  write; Read only shall offer no sending tool (spec 002 pattern, Constitution III).
- **FR-1231** When Claude sends a WhatsApp message, the system shall show a notification and list
  it in the menu bar activity, as for Messages.
- **FR-1232** Settings shall tell the Owner in one plain sentence that WhatsApp's terms forbid
  automated messaging and that a ban, though unlikely for personal use, is possible (Toni,
  2026-11-02), and what WhatsApp needs on the Mac (logged in to WhatsApp Web in Safari).

## Success criteria

- **SC-1201** With the Mac locked and the lid closed, "WhatsApp <person> <text>" from Claude on a
  phone sends the message through the Safari tab, and the person receives it, within 60 s; or,
  where Safari doesn't answer while locked, Claude says so at once.
- **SC-1202** Withdrawn 2026-11-04 (staying linked for 24 hours).
- **SC-1204** With the Safari tab closed and Safari unable to open one, "WhatsApp the family
  group <text>" goes out through WhatsApp for Mac with the Mac unlocked, and is answered at once
  with why with the Mac locked.
- **SC-1203** While the Owner types in another app, a send through the Safari tab causes no focus
  change, window, or pointer movement (checked with `focus.log` from the screen-state checks).

## Open questions

None.
