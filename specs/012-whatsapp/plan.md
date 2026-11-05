# Plan 012: WhatsApp — HOW

Spec: `spec.md`. Research and every test behind these choices: `research.md`. Rebuilt on
2026-11-04 after Toni chose (spec FR-1206, FR-1215, FR-1222): no linked device of Latchkey's own;
the Owner's WhatsApp Web tab in Safari first, WhatsApp for Mac's window as the fallback for
sending; WhatsApp for Mac's database for reading while that app runs. The first build (0.8.101 to
0.8.114) ran WhatsApp Web in a hidden page of Latchkey's own, linked by QR or code; what it taught
is kept below where it still applies.

## D1 The Owner's WhatsApp Web tab in Safari

Serves FR-1206, FR-1208, FR-1214, FR-1215, FR-1222.

- `SafariWhatsApp` finds the first tab in any Safari window whose address starts with
  `https://web.whatsapp.com` and runs JavaScript in it with Safari's `do JavaScript` (AppleScript,
  through `osascript` like every Safari script, spec 005). It never selects, reloads, navigates,
  or closes the tab, and never activates Safari (FR-1208).
- Safari's `do JavaScript` returns at once and can't wait for a page's promise. Each call is one
  script that injects the bridge (D2) when the page lacks it or has an older version, starts the
  bridge function with its answer kept in `window.__lkr[<random id>]`, then asks for that answer
  every 0.2 s until it comes or the call's time is up. Options weighed: one `do JavaScript` per
  poll from Swift (an `osascript` start each, about 0.1 s), or the polling inside one AppleScript
  (one process). Chosen: inside one AppleScript.
- The arguments go to the page as JSON written into the script text (JSON is JavaScript), and the
  function name is one of the bridge's fixed names; the user's text never becomes code.
- Needs Safari's Develop → Allow JavaScript from Apple Events (as the browser tools do, spec 005)
  and Automation for Safari. When either is missing, or no WhatsApp tab is open, or Safari doesn't
  answer (seen 2026-11-01 with the Mac locked), the tab counts as unusable with that reason.
- No watchdog: the tab is the Owner's. A tab stuck connecting is reported, not reloaded.
- Several WhatsApp tabs: the first one found (window order, then tab order).

## D2 Driving WhatsApp Web: its own functions, not its screen

Serves FR-1213, FR-1214, FR-1220, FR-1222.

The screen can't be driven: script clicks on the chat list do nothing, the photo preview's
controls lie outside the page, and a draft left in the message box gets sent with the next
message (research, second round). WhatsApp Web's own modules, reached with `window.require`, do
everything:

| Need | Function |
|---|---|
| Connection | `WAWebSocketModel.Socket.state` (`CONNECTED`) |
| Chats, groups, names | `WAWebCollections.Chat.getModelsArray()`; group when `id.server == "g.us"`; `formattedTitle` |
| A person by number | `WAWebFindChatAction.findOrCreateLatestChat(WAWebWidFactory.createWid("<digits>@c.us"))` |
| Text | `WAWebSendTextMsgChatAction.sendTextMsgToChat(chat, text)` |
| Photo or file | `WAWebMediaOpaqueData.createFromData(file, type)`, `WAWebPrepRawMedia.prepRawMedia(data, {asDocument})`, `waitForPrep()`, `sendToChat({chat, options: {caption}})` |
| Confirmation | the chat's `msgs`: the new message with `id.fromMe` and `ack` ≥ 1 (1 server, 2 delivered, 3 read) |
| Older messages | `WAWebChatLoadMessages.loadEarlierMsgs({chat})` |

All of this is one JavaScript source (`WhatsAppBridge.swift`) that defines `window.__latchkey`
with a function per operation and checks that every module it needs exists; when WhatsApp
renames one, the tools say which, and that Latchkey needs an update. Message ids have no
`_serialized` (use `String(id)`); the text-send promise settled about 38 s after the message was
out (2026-11-03), so the message in the chat with `ack` ≥ 1 is the confirmation. `screen()` gives
the page's words while no chats show (a loading or sync screen), so an unusable tab's answer says
why; the log-in screen counts only while no chats show (a message's words can't fake it).

## D3 WhatsApp for Mac's window, for sending only

Serves FR-1215, FR-1212.

- Used only when the Safari tab is unusable before anything was sent (FR-1216), the Mac is
  unlocked, and the message is text to a person (a number, or a chat in the database whose id is
  `<digits>@s.whatsapp.net`); otherwise the answer says why nothing was sent.
- WhatsApp for Mac can't be scripted (no AppleScript dictionary; research). Latchkey opens
  `whatsapp://send?phone=<digits>&text=<text>`, which opens the chat with the text in the box,
  waits for WhatsApp to be in front with that text in its focused field (Accessibility, as the
  computer tools use), presses Return in WhatsApp alone (a key event posted to its process), and
  brings back the app that was in front.
- Confirmation: the message in WhatsApp for Mac's database, from the Owner, with that text, within
  15 s; otherwise the answer says it may have gone (never retried).

## D4 Latchkey's own device, removed

Serves FR-1206, FR-1207.

- No hidden page, no `whatsapp_link`, no linking window, no Settings link row. The bridge has no
  log-in or log-out functions.
- At the first start of this version (once, recorded in Latchkey's settings), Latchkey deletes the
  website data store of its old device (fixed identifier `6F1C2A4E-…`) and the `whatsappLinked`
  flag. WebKit must be set up first (a web view made) or deleting a store crashes (0.8.101).

## D5 Tools

Serves FR-1212 to FR-1232. Names follow Messages (spec 002).

- `whatsapp_find` (read): with nothing, the chats newest first (name, group or person, unread
  count, last message time); with `text`, `chat`, `since`, `until`: messages; `person`, `unread`,
  `limit`, `offset`.
- `whatsapp_read` (read): one chat's messages by `chat` (name, number, or id), `limit`, `before`.
- `whatsapp_send` (write): `to`, `text`, `files`. One match is required: several give the
  candidates and nothing is sent (FR-1213). Through the tab (D1) or the window (D3); the answer
  says which.
- Reading source (FR-1222): the database while WhatsApp for Mac runs; else the tab when connected;
  else the database, saying how old its newest message is; else an answer saying neither is there.
  A chat's time and preview come from its last message (`ZLASTMESSAGE`): `ZLASTMESSAGEDATE` is a
  sort key WhatsApp moves thousands of years ahead for a pinned chat, and `ZLASTMESSAGETEXT` is
  encoded. Senders known only by privacy id (`…@lid`) get their names from WhatsApp's copy of the
  address book, `ContactsV2.sqlite`.
- Files are checked for size and kind before they are read (security review 2026-11-03); at most
  64 MB per call; photos (`image/*`) go as photos, anything else as documents.
- Settings, WhatsApp section: one line on what WhatsApp needs on the Mac and the warning
  (FR-1232).

## D6 Deadline

Serves FR-1212. `whatsapp_send` declares 60 s (spec 001 FR-011's cap): up to 10 s to check the
tab, 38 s for a send through it, or about 20 s through the window.

## D7 Off

Serves FR-1230. At Off the tools disappear (Constitution III); nothing is logged out (Latchkey
linked nothing). Read only removes `whatsapp_send`.

## Constitution check

- I (outbound only): nothing listens; Safari and WhatsApp for Mac make their own connections.
- II (fail fast): every Safari script has a deadline; an unusable tab or a locked Mac answers at
  once with why.
- III (off is invisible): Off removes the tools.
- IV (real Mac app): AppleScript, a URL scheme, and Accessibility; all Apple-supported.
- VI (relay stores no results): unchanged.
- VII (tests first): bridge contract tests run the JavaScript against a stand-in of WhatsApp's
  modules; the Safari call's JavaScript runs in a real WebKit view; tool tests use fake tab and
  window and a fixture copy of the desktop database; the live check runs against real WhatsApp.
