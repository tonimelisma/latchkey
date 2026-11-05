# Plan 012: WhatsApp — HOW

Spec: `spec.md`. Research and every test behind these choices: `research.md`. Decided by Claude
on 2026-11-03 after Toni said to complete the work without stopping to ask; each choice below
names the options weighed.

## D1 Latchkey's own linked device: a hidden WhatsApp Web page in the Mac app

Serves FR-1201, FR-1202, FR-1210, FR-1211.

- A `WhatsAppPage` (main actor) owns one `WKWebView` in a borderless window placed off screen,
  never shown except while linking (D3). It loads `https://web.whatsapp.com/` with the installed
  Safari's user agent (as the locked browser does, spec 005 plan D7).
- Its website data lives in a persistent store of its own,
  `WKWebsiteDataStore(forIdentifier:)` with a fixed identifier, apart from Safari and from the
  locked browser. WebKit wraps the page's stored keys with a Keychain key of Latchkey's own
  (`com.apple.WebKit.WebCrypto.master+<bundle id>`), so the store works only for the signed app.
- The page's main frame may only be `https://web.whatsapp.com` (other navigations are cancelled),
  and every call into it checks that first, so messages and files go to WhatsApp Web alone
  (security review 2026-11-03).
- `WKPreferences.inactiveSchedulingPolicy = .none` (public since macOS 14): a hidden page's timers
  are otherwise slowed tenfold (research: 3.4 s of steps took 30 s).
- The page runs while WhatsApp is on and linked, so sends are warm (about 1 s). Options weighed:
  start the page per call (no memory use while idle, but about 15 s per call and a new history sync
  each time) or keep it open (about 150 MB, answers in a second). Kept open.

## D2 Driving the page: WhatsApp Web's own functions, not its screen

Serves FR-1210, FR-1213, FR-1214, FR-1220, FR-1221.

The screen can't be driven: script clicks on the chat list do nothing, the photo preview's
controls lie outside the page, and a draft left in the message box gets sent with the next
message (research, second round). WhatsApp Web's own modules, reached with `window.require`, do
everything, tested with the Mac locked:

| Need | Function |
|---|---|
| Connection | `WAWebSocketModel.Socket.state` (`CONNECTED`) |
| Chats, groups, names | `WAWebCollections.Chat.getModelsArray()`; group when `id.server == "g.us"`; `formattedTitle` |
| A person by number | `WAWebFindChatAction.findOrCreateLatestChat(WAWebWidFactory.createWid("<digits>@c.us"))` |
| Text | `WAWebSendTextMsgChatAction.sendTextMsgToChat(chat, text)` |
| Photo or file | `WAWebMediaOpaqueData.createFromData(file, type)`, `WAWebPrepRawMedia.prepRawMedia(data, {asDocument})`, `waitForPrep()`, `sendToChat({chat, options: {caption}})` |
| Confirmation | the chat's `msgs`: the new message with `id.fromMe` and `ack` ≥ 1 (1 server, 2 delivered, 3 read) |
| Older messages | `WAWebChatLoadMessages.loadEarlierMsgs({chat})` |

All of this lives in one JavaScript file in the app's resources (`WhatsAppBridge.js`), injected
into the page as a user script that defines `window.__latchkey` with a function per operation
and checks that every module it needs exists. Swift calls them with `callAsyncJavaScript` and
named arguments (no string building). When WhatsApp renames a module, the check says which one,
and the tools answer that WhatsApp Web changed and Latchkey needs an update, at once.

Options weighed: the screen (proven unworkable), an unofficial protocol library such as whatsmeow
(no browser, but WhatsApp can tell it isn't its own client, and Latchkey would carry the
protocol), WhatsApp Web's own functions (its own client; the module names can change with
WhatsApp's releases). Chosen: WhatsApp Web's functions.

## D3 Linking

Serves FR-1201, FR-1204, FR-1205, FR-1232.

- Settings, WhatsApp row: **Link WhatsApp…** opens a window that shows the page itself, with
  WhatsApp's own QR code and its "Log in with phone number" (which gives an 8-character code to
  type on the phone). Above it, the one-sentence warning (FR-1232). When the chat list appears the
  window closes, the page goes back off screen, and the row says "Linked".
- From anywhere (FR-1205): `whatsapp_link` starts the page, presses WhatsApp Web's own "Log in
  with phone number", types the number, and returns the code it shows. This is the only use of
  the screen: the log-in screen has no module to call. A page nobody linked closes after 10
  minutes and its data is deleted.
- Whether the device is linked is a flag Latchkey keeps (`whatsappLinked` in its settings), set
  once the page is connected and cleared at unlink. Asking WebKit for its stores
  (`allDataStoreIdentifiers`) before any web view exists crashed 0.8.101 at every start.
- On the log-in screen WhatsApp Web hasn't loaded its modules, so "WhatsApp Web changed" is said
  only by a page showing its chats.
- When the page shows the login screen again (removed on the phone, logged out by WhatsApp), the
  row says "Not linked", the Owner gets one notification, and every tool answers that WhatsApp
  needs linking in Latchkey's Settings.

## D4 Staying connected

Serves FR-1202, FR-1212, SC-1202.

- Every 30 s the app reads `Socket.state`. When it hasn't been `CONNECTED` for 60 s, the app
  reloads the page (research: stuck for 7 hours overnight; a reload connected in 10 s, locked).
- Before a send the app checks the state; when it isn't connected, it reloads and waits up to
  20 s for `CONNECTED`, then answers "WhatsApp isn't connected" if it still isn't. Nothing is
  queued (Toni, 2026-11-02).
- If the web content process dies, the app reloads the page (WebKit's termination callback).
- A call into the page answers within its own timeout even when WebKit holds it (seen overnight):
  the call and a timer race, and the first answers.
- WhatsApp's text-send promise settled about 38 s after the message was out (2026-11-03), so the
  message itself in the chat, with `ack` ≥ 1, is the confirmation; a rejected promise ends the
  wait at once.
- Log-out is the connection's own `WAWebSocketModel.Socket.logout()` (`WAWebCmd` has none).
- No reload for 10 minutes after a link starts: a reload throws the waiting code away, and the
  phone then says it couldn't find the device (2026-11-04, 0.8.111). The code screen counts as
  the log-in screen.

## D5 Tools

Serves FR-1210 to FR-1230. Names follow Messages (spec 002).

- `whatsapp_find` (read): with nothing, the chats newest first (name, group or person, unread
  count, last message time); with `query`, chats whose name or number matches, and messages whose
  text matches; `chat`, `since`, `until`, `unread`, `limit`, `offset`.
- `whatsapp_read` (read): one chat's messages, newest first, by `chat` (name, number, or the id
  `whatsapp_find` gives), `limit`, `before`.
- `whatsapp_send` (write): `to` (a chat's id, a group's or person's name, or a phone number with
  country code), `text`, `files` (paths on the Mac). One match is required: several give the
  candidates and nothing is sent (FR-1213). Answers once WhatsApp has the message (`ack` ≥ 1),
  saying it was sent, or delivered or read when it already knows; when the message doesn't reach
  WhatsApp within the deadline, it says it may not have gone and is never retried (spec 008's rule
  for Mail).
- Reading source (FR-1221): the desktop app's `ChatStorage.sqlite` when it exists and opens,
  otherwise the page. Each answer says which, and the page's answer says its history is shorter.
  A chat's time and preview come from its last message (`ZLASTMESSAGE`): `ZLASTMESSAGEDATE` is a
  sort key that WhatsApp moves thousands of years ahead for a pinned chat, and
  `ZLASTMESSAGETEXT` is encoded. Senders known only by privacy id (`…@lid`) get their names from
  WhatsApp's copy of the address book, `ContactsV2.sqlite` (`ZWAADDRESSBOOKCONTACT`: `ZLID`,
  `ZFULLNAME`).
- Files are checked for size and kind before they are read (security review 2026-11-03). Any
  readable file can be sent, as with `messages_send` (Toni's standing choice: no limits on what
  Claude may be asked to send).
- A file is read on the Mac and handed to the page as bytes; photos (`image/*`) go as photos,
  anything else as a document with its file name. At most 64 MB per call (the bytes cross into
  the page in memory).

## D6 Deadline

Serves FR-1212. `whatsapp_send` declares a 30 s deadline (room for a reload, D4) within the
60 s cap (spec 001 FR-011); the read tools use the default.

## D7 Off

Serves FR-1203, FR-1230. At Off the tools disappear (Constitution III), the page logs out through
WhatsApp Web's own log-out (which removes it from the phone's Linked Devices), and the website
data store is deleted. Read only keeps the page for reading when the desktop app isn't there and
removes `whatsapp_send`.

## Constitution check

- I (outbound only): the page connects out to WhatsApp; nothing listens.
- II (fail fast): every page call has a deadline; a disconnected page answers at once with why.
- III (off is invisible): Off removes the tools and unlinks.
- VI (relay stores no results): unchanged; messages pass through like any tool result.
- VII (tests first): bridge contract tests run the JavaScript against a stand-in of WhatsApp's
  modules; tool tests use a fake page and a fixture copy of the desktop database's schema; the
  live check runs against real WhatsApp.
