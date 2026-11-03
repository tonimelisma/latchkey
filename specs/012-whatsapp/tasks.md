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
- [ ] T7 Live check of sending through Latchkey's own device, unlocked and locked (needs Toni to
  type a link code once)
