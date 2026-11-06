# Tasks 012: WhatsApp

Built 2026-11-03 in one pass after Toni said to complete the work; each task was tested before the
next. Tests: `macos/Tests/WhatsAppBridgeTests.swift` (the bridge in real WebKit against a stand-in
of WhatsApp Web), `WhatsAppStoreTests.swift` (a database in WhatsApp for Mac's layout),
`WhatsAppToolsTests.swift` (the tools against a stand-in page).

- [x] T1 Bridge: state, chats, resolve, messages, search, send (text, photos, files), log-out,
  link by phone code (plan D2, D3)
- [x] T2 Page: hidden web view, own data store, no background slowing, watchdog and reload,
  linking window, unlink (plan D1, D3, D4, D7)
- [x] T3 Desktop database reader: chats (pinned, real last message), messages with senders and
  kinds, search, address-book names (plan D5)
- [x] T4 Tools: `whatsapp_find`, `whatsapp_read`, `whatsapp_send`, `whatsapp_link` (plan D5, D6)
- [x] T5 Settings row (Link WhatsApp…, Unlink…), start at launch, Off unlinks (plan D3, D7)
- [x] T6 Live checks through the hosted relay: listing chats, reading a group, getting a link code
- [x] T7 Live check of sending through Latchkey's own device (2026-11-04): text, a photo and a
  file sent and read; then the first history sync paused, the device dropped after two app
  restarts, and WhatsApp logged out every linked device of the account. Design withdrawn.

Rebuilt 2026-11-04 (Toni: no device of Latchkey's own; Safari tab first, window as fallback):

- [x] T8 Bridge in the Owner's Safari tab: start and collect through `do JavaScript`, origin
  checked in the page, link and log-out functions removed (plan D1, D2)
- [x] T9 WhatsApp for Mac's window: `whatsapp://send`, Return in WhatsApp alone, confirmed in
  its database (plan D3)
- [x] T10 Tools: Safari first, window fallback, reading order; `whatsapp_link` removed (plan D5)
- [x] T11 Old device's data deleted once at start; Settings says what WhatsApp needs (plan D4)
- [x] T12 Live check through the hosted relay, 2026-11-04, to the Owner's own chat: through the
  Safari tab (0.8.116: sent, read within seconds, Safari stayed behind), reading by number
  (0.8.117, after chats filed by privacy id were found), through WhatsApp for Mac with the tab
  closed (0.8.117: sent, confirmed in its database). Not yet checked: a send through the tab
  with the Mac locked.
- [x] T13 WhatsApp for Mac's window removed; with no WhatsApp tab, one is opened in Safari
  (Toni, 2026-11-04; plan D1)
- [x] T14 Live check: with the tab closed and the Mac locked, a send opens the tab and goes out
  (2026-11-05, 14:15, to the Owner's own chat; message deleted afterwards)

Extended 2026-11-05 (Toni: "add everything missing"):

- [x] T15 Bridge: message keys, replies, reactions, deleting, "me" (plan D2, D5); checked live in
  Safari's WhatsApp Web tab with the Mac locked, in the Owner's own chat, every message deleted
- [x] T16 Database: message by id, the Owner's own chat by account, stamps, lookalikes (plan D5)
- [x] T17 Tools: `reply_to`, `whatsapp_change`, older history while reading through the tab,
  WhatsApp for Mac as the fallback (plan D3b, D5)
- [x] T18 WhatsApp for Mac's window through Accessibility: open chats with certainty, find
  messages, delete, react, reply, send text and files (plan D3b); unit-tested, with deleting
  checked live by hand (seven messages, 2026-11-05)
- [x] T20 Live check of WhatsApp for Mac's window unlocked (2026-11-05 evening, the Owner's own
  chat): text in the background through the link, reply, file and text, react and unreact, delete
  for everyone refused by WhatsApp, delete for me; every message deleted and checked gone twice
- [ ] T21 Live: a group and a person without a known number through WhatsApp for Mac (only in
  chats Toni names for testing), and the lid closed while unlocked
- [x] T19 Screen-state cases `whatsapp.*` and `sweep.whatsapp`
