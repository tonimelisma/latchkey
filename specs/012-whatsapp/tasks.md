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
- [ ] T12 Live check, one message per way, to the Owner's own chat (Toni: today)
