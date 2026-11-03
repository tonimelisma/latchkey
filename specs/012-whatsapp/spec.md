# Spec 012: WhatsApp — WHAT and WHY

Status: Draft for Toni's review (2026-11-02). Questions for Toni are marked NEEDS CLARIFICATION.
Scope: Claude reads, searches, and sends the Owner's WhatsApp messages from any Claude app,
through the Mac, including while the Mac is locked.
Out of scope: calls, status updates, communities and channels, changing WhatsApp settings.

Research, with the tests run on Toni's Mac: `research.md`.

## Problem

Many people's family and friends are on WhatsApp, not iMessage. "Tell my wife I'm on my way",
"what did the group say about Saturday?" need WhatsApp, and the Owner is usually away from the
Mac when they ask: the Mac is at home, locked, often with the lid closed. Queueing a message until
the next unlock is useless for messaging.

## User stories

### US1 (P1): Send a WhatsApp message from anywhere, now
As an Owner, I ask Claude to send a WhatsApp message, and it goes out right away, even though my
Mac is locked.

1. Given WhatsApp is set to Read & write and my Mac is locked, when I say "WhatsApp my wife I'm
   on my way", then the message is sent within a minute and Claude says it was sent.
2. Given the message can't be sent (WhatsApp not linked, Mac offline, page not answering), then
   Claude says so at once, in plain words, and nothing is sent later without being asked again.
3. Given I'm using the Mac, when Claude sends a message, then no window appears and nothing
   takes focus.

### US2 (P1): Read and search my WhatsApp
1. Given WhatsApp is Read only or Read & write, when I ask "what did the family group say about
   Saturday?", then Claude finds the messages and answers, with names rather than numbers.
2. Given I ask for my unread WhatsApp messages, then Claude lists them by chat.

### US3 (P1): Set up once, see it, undo it
1. When I turn on WhatsApp in Latchkey, then Latchkey shows a QR code, I scan it with WhatsApp
   on my phone, and Latchkey says it's linked.
2. Latchkey appears in my phone's Linked Devices like any other linked device; removing it there
   or turning WhatsApp off in Latchkey logs it out.
3. Given WhatsApp is Off, then no WhatsApp tool exists (Constitution III).

### US4 (P1): See what Claude sent
1. Given Claude sent a WhatsApp message, then my Mac shows a notification and the menu bar
   activity lists it (as for Messages, spec 002).

## Requirements

### Linking

- **FR-1201** When the Owner turns WhatsApp on, the system shall link itself to the Owner's
  WhatsApp account as its own linked device by a QR code the Owner scans with WhatsApp on their
  phone, without using or changing any browser's existing WhatsApp session.
- **FR-1202** The system shall stay linked across restarts of the Mac and of Latchkey, without
  asking the Owner to scan again, until the Owner or WhatsApp unlinks it.
- **FR-1203** When the Owner turns WhatsApp off, the system shall log its linked device out and
  delete what it stored for WhatsApp.
- **FR-1204** When WhatsApp unlinks the system (removed on the phone, logged out by WhatsApp),
  the system shall tell the Owner on the Mac and answer every WhatsApp tool call by saying
  WhatsApp needs linking again.

### Sending

- **FR-1210** When Claude asks to send a WhatsApp message to a person or chat, the system shall
  send it through its linked device, whether the Mac is unlocked or locked, and answer once the
  message has left the Mac.
- **FR-1211** The system shall send without showing a window, taking focus, moving the pointer, or
  using the clipboard.
- **FR-1212** When the system can't send, it shall answer within the call's deadline (spec 001
  FR-011) saying why, and shall not send the message later on its own.
- **FR-1213** When the recipient matches more than one chat or contact, the system shall not send,
  and shall answer with the candidates so Claude can ask the Owner.
- **FR-1214** [NEEDS CLARIFICATION: Can Claude send to groups, and send photos and files, in the
  first version, or text to one person only?]

### Reading

- **FR-1220** When Claude asks for chats or messages, the system shall find them by person, chat,
  words, date, and unread, and show names from the Owner's contacts and WhatsApp's own names
  rather than numbers.
- **FR-1221** [NEEDS CLARIFICATION: Where reading comes from. The desktop WhatsApp app's database
  (tested: complete history, works locked, but needs the desktop app installed and running), or
  Latchkey's own linked device (works without the desktop app; history limited to what WhatsApp
  syncs to a new device), or the database when present and the linked device otherwise?]

### Permissions and visibility

- **FR-1230** WhatsApp shall have the same three settings as Messages: Off, Read only, Read &
  write; Read only shall offer no sending tool (spec 002 pattern, Constitution III).
- **FR-1231** When Claude sends a WhatsApp message, the system shall show a notification and list
  it in the menu bar activity, as for Messages.
- **FR-1232** [NEEDS CLARIFICATION: WhatsApp's terms forbid automated messaging, and accounts can
  be banned. Does setup tell the Owner this in a sentence before linking, or not at all?]

## Success criteria

- **SC-1201** With the Mac locked and the lid closed, "WhatsApp <person> <text>" from Claude on a
  phone sends the message, and the person receives it, within 60 s.
- **SC-1202** After 24 hours with the Mac locked and asleep in between, a send still works without
  re-linking.
- **SC-1203** While the Owner types in another app, a send causes no focus change, window, or
  pointer movement (checked with `focus.log` from the screen-state checks).

## Open questions

All questions for Toni are the NEEDS CLARIFICATION items above (FR-1214, FR-1221, FR-1232).
