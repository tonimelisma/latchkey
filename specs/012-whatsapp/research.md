# Research 012: WhatsApp

Started 2026-11-02. Tests were run on Toni's Mac (macOS 27.0.1, Safari 27.0.1, WhatsApp for Mac
26.42.79) with throwaway programs, deleted afterwards. Facts marked "not yet checked" come from
general knowledge and still need a primary source before the plan relies on them.

## Two WhatsApps on the Mac

- **WhatsApp for Mac** (`/Applications/WhatsApp.app`) is an iPad-style (Mac Catalyst) app built on
  UIKit and SwiftUI. It has no AppleScript dictionary (`sdef` fails), and System Events saw zero
  elements in its window, so its interface can't be driven the way Mail and Messages are. Its URL
  scheme (`whatsapp://send?phone=…&text=…`) only fills in a message; pressing Send needs the
  window, which needs an unlocked screen and takes focus.
- **WhatsApp Web** (`web.whatsapp.com`) runs in any recent browser, including WebKit.

## Reading: the desktop app's database (tested)

- WhatsApp for Mac keeps its messages in SQLite files in
  `~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/`: `ChatStorage.sqlite` (tables
  `ZWAMESSAGE`, `ZWACHATSESSION`, `ZWAGROUPMEMBER`, `ZWAMEDIAITEM`, …), `ContactsV2.sqlite`,
  `CallHistory.sqlite`, and others. Core Data layout; dates are seconds since 2001.
- macOS protects the folder: a plain shell gets "Operation not permitted"; Latchkey (Full Disk
  Access) opened it read-only. On 2026-11-02 it held 27,131 messages in 102 chats, the newest a
  few minutes old: the app keeps it current while it runs.
- This is the same pattern as Messages (spec 002): read the database, never write it. It works in
  every screen state, locked included, because nothing is drawn.
- Messages sent from Latchkey's own linked device (below) showed up in this database within
  seconds (`ZISFROMME = 1`), so it also confirms a send reached WhatsApp's servers.

## Sending: what does not work (tested)

1. **Safari's cookies in a fresh WebKit page.** Safari holds three cookies for
   `.web.whatsapp.com`: `wa_web_lang_pref`, `wa_ul`, and `wa_web_access_token` (148 characters).
   A hidden WebKit page given all three still showed the login QR code. WhatsApp Web's login is
   not in cookies.
2. **A copy of Safari's whole WhatsApp storage.** Safari keeps about 475 MB for the site
   (IndexedDB 253 MB, service workers, cache, local storage) under
   `~/Library/Containers/com.apple.Safari/Data/Library/WebKit/WebsiteData/Default/<salted origin>/`.
   Copied with Safari's salt into a test page's own store (same layout), the page stopped at
   "Don't close this window. Your messages are downloading" for two minutes and never reached
   the chats. WebKit logged "Could not find WebCrypto master key in Keychain": WebKit wraps the
   encryption keys a site stores with a per-app key in the login Keychain (account
   `com.apple.WebKit.WebCrypto.master+<bundle id>`, seen for Safari and for each test program).
   A copy carries the wrapped keys but not the means to unwrap them. Safari's own tab stayed
   logged in throughout (checked every 10 s).

## Sending: Latchkey's own linked device (tested, works)

A signed test app (Toni's Apple Development certificate, its own bundle id) opened WhatsApp Web
in a WebKit page with a persistent store of its own (`WKWebsiteDataStore(forIdentifier:)`) and a
Safari user agent.

- **Linking:** the page showed the QR code; Toni scanned it with his phone; the chat list
  appeared in about 10 s. No Keychain errors: the signed app could create its own WebCrypto key
  (an unsigned command-line program earlier logged "Cannot store WebCrypto master key").
- **Staying logged in:** quit and restarted with no visible window, it reached the chat list in
  18 s from cold.
- **Sending, unlocked:** loading `https://web.whatsapp.com/send?phone=<number>&text=<text>`, then
  clicking the Send button from a script, sent the message to Toni's own chat ("Message
  yourself"). Ready to click after about 12 s; whole cold run about 30 s.
- **Sending, locked:** with the Mac locked (Control-Command-Q, lock confirmed by
  `CGSSessionScreenIsLocked`), the same program sent a second message 20 s after the lock; the
  desktop app recorded it at 20:42:47, and the Mac was still locked when the run ended.
- **Logging out:** WhatsApp Web's own menu (Log out, then confirm) from a script returned the page
  to the QR code, which also removes it from the phone's Linked Devices.
## Second round (2026-11-02 evening, a long-running test app, Mac mostly locked)

A signed test app kept the page open and took commands; it logged the page's state every 30 s.

- **Linking without the QR code:** WhatsApp Web's "Log in with phone number" takes the Owner's
  number (the test read it from the desktop app's `LID.sqlite`, table `ZWAZACCOUNT`) and shows an
  8-character code; Toni typed it on his phone (Linked Devices, Link with phone number instead)
  and the page linked in about two minutes. This works with the Owner away from the Mac. The
  fresh page first said "A database error occurred on your browser. Please relink your device",
  but linking worked.
- **Background slowing:** a hidden page's timers are slowed: a send whose own waits added to
  3.4 s took 30 s. `WKPreferences.inactiveSchedulingPolicy = .none` (public, macOS 14) removes
  it: the same steps then took under a second.
- **Opening the right chat:** script clicks and synthetic keys on WhatsApp Web's chat list and
  search results do nothing; earlier "fast" sends only reached Toni's own chat because it was
  already open. Loading `https://web.whatsapp.com/send?phone=…&text=…` works for people (13.5 s,
  reloads the page) but not groups. What works: WhatsApp Web's own modules, the same ones
  `whatsapp-web.js` uses: `window.require('WAWebCollections').Chat` lists every chat (101, of
  which 41 groups, `id.server === 'g.us'`; the desktop app has 102 and 41), and
  `window.require('WAWebCmd').Cmd.openChatBottom({chat})` opens one, groups included (1.9 s).
- **Typing safely:** the message box is a Lexical editor. A draft left in it is kept, and
  `insertText` adds to it: one test message went out with the earlier draft glued on (to Toni's
  own chat). Clearing needs the editor's own `beforeinput` `deleteContentBackward` after its
  selection catches up (about 150 ms); the send must refuse when the box isn't empty or the typed
  text isn't exactly the message. Both checks were tested with junk left in the box.
- **Sending, locked, confirmed by WhatsApp itself:** from a group, open the own chat by command,
  check the box, type, check, click Send, then find the message in the chat's `msgs` with
  `id.fromMe` and watch `ack` (1 server, 2 delivered, 3 read): opened 0.14 s, clicked 0.41 s,
  read 1.16 s, with the Mac locked.
- **Reading through the page:** WhatsApp Web's chat list and messages are in memory
  (`Chat.getModelsArray()`, each chat's `msgs`); a group showed one message in memory until more
  is loaded. How far back history goes for a new linked device: not yet measured.
- **Desktop app not always running:** WhatsApp for Mac was not running from 20:42 on, so its
  database stopped there: reading from it needs the app open, which supports FR-1221's fallback.
- **Photos through the preview don't work.** While locked the page gets no animation frames at all
  (unlocked, off-screen: it does). A picture put in the file input opens WhatsApp's preview, but
  neither a script click on its Send button, Enter in the message box, nor a native mouse event
  delivered to the web view sends it; the preview's controls lie outside the page's width.
- **Photos and files through WhatsApp Web's own functions work, locked (2026-11-03):**
  `require('WAWebMediaOpaqueData').createFromData(file, type)`, then
  `require('WAWebPrepRawMedia').prepRawMedia(data, {asDocument})`, `waitForPrep()`, and
  `prep.sendToChat({chat, options: {caption}})`. A PNG was read at 1.0 s, a text file sent as a
  document (`asDocument: true`, file name kept) at 0.8 s.
- **Snapshots** of the page are blank while the Mac is locked (nothing is drawn).

## Overnight (2026-11-02 21:27 to 2026-11-03 07:36, Mac locked from 23:18)

- The page stayed signed in all night: 1,214 heartbeats, all with the chat list, none late.
- Sends at 21:27 and 23:27 (locked) were read within 2 s. From 00:36 the page showed "Connecting
  to WhatsApp / Retrying… Retry now" and stayed so for 7 hours, while Latchkey's own connection
  and the network were fine (`navigator.onLine` true). Sends at 01:27, 03:28, 05:29, 07:31 never
  finished (WebKit later dropped the calls: "Completion handler … no longer reachable"). Earlier
  short drops (22:49 to 23:06, unlocked) recovered by themselves within minutes.
- "Retry now" (a script click) didn't help; **reloading the page did: connected 10 s later, still
  locked**, and a send was read at 0.6 s.
- WhatsApp Web's own connection state: `require('WAWebSocketModel').Socket.state` (`CONNECTED`
  when up); the on-screen banner says the same in words. The heartbeat that only looked for the
  chat list missed the outage: the chat list stays on screen while disconnected.
- Consequence for the plan: watch `Socket.state`, reload when it isn't `CONNECTED` for a while,
  and check it before every send (reload and wait when needed).

## History through the page (2026-11-03)

- `require('WAWebChatLoadMessages').loadEarlierMsgs({chat})` loads older messages a page at a
  time. Toni's family group: 317 messages back to 2026-08-05 on the new linked device; the desktop
  app's database has 757 back to 2025-11-03. So the desktop database is the better reading source
  when present (FR-1221), and the page is a shorter fallback.
- Not yet tested: the lid closed; the phone offline for long.

## Timing against Claude's limits

- Latchkey's per-call deadline defaults to 10 s, capped at 60 s (spec 001 FR-011). A cold start
  plus send (about 30 s) fits under the cap but not the default; a page kept running between calls
  would answer in a few seconds. The plan has to pick one.

## Rules and limits

- WhatsApp's terms (effective 2021-01-04, checked 2026-11-02) forbid "bulk messaging,
  auto-messaging, auto-dialing, and the like", using the service "in impermissible or
  unauthorized manners", and doing harmful things "directly or through automated means"; WhatsApp
  may suspend or end an account that breaks them. They don't name unofficial clients or say
  "only our apps". Latchkey's linked device runs WhatsApp's own web client in a real WebKit
  browser and sends one message when the Owner asks, which is personal use, not bulk; it is
  still scripted, so a ban is possible though unlikely.
  https://www.whatsapp.com/legal/terms-of-service
- `lharries/whatsapp-mcp` (MIT) connects as a linked device through whatsmeow, an unofficial Go
  library speaking WhatsApp's multi-device protocol; it stores messages in its own SQLite database
  and says re-linking is needed after about 20 days. https://github.com/lharries/whatsapp-mcp,
  https://github.com/tulir/whatsmeow
- Linked devices: how many are allowed, whether they keep working while the phone is offline, and
  when they are logged out: not yet checked (WhatsApp's Help Center page didn't load for the
  fetcher).

## 2026-11-04: what linking Latchkey's own device cost

- Five link codes for Toni's number in two days, two test devices linked and deleted, a
  storage-copy attempt, and Latchkey's device dropping and relinking (a watchdog reload and two
  app installs during the first history sync, a 10-minute self-delete). After that WhatsApp
  logged out every linked device of the account; the phone stayed logged in.
- WhatsApp's help pages: a restricted account (spam, automation) "may also be logged out of some
  companion devices" (https://faq.whatsapp.com/717472490411581); linking an account to an
  unofficial app "may result in a temporary or permanent account ban"
  (https://faq.whatsapp.com/1848531392146538); the Messaging Guidelines list "unofficial clients
  … auto-messaging … or automation" as abuse (https://www.whatsapp.com/legal/messaging-guidelines).
- A new linked device's first history sync stops when WhatsApp isn't open on the phone ("Keep app
  open on both devices"); while it waited, the page wasn't connected and sends failed.
- So Latchkey links nothing (spec FR-1206). The options weighed with Toni: WhatsApp for Mac's
  database (no network, safe), its window (the official app, unlocked only), the Owner's Safari
  tab (no new linking; scripted, medium risk), Latchkey's own device (withdrawn), WhatsApp's
  business service (not from the Owner's number).
- Safari while locked: on 2026-11-01 Safari stopped answering scripts with the Mac locked
  (spec 005); whether a WhatsApp send through the tab works locked is part of the live check.

## 2026-11-05: replies, reactions, deleting, and WhatsApp for Mac again

Toni asked to "add everything missing": the window fallback for groups, contacts without a
known number, files, and more screen states; replies, reactions, and deleting on both paths;
older history. Tests on Toni's Mac (macOS 27.0.1, WhatsApp for Mac 2.26.43.75), only in his own
"Message yourself" chat, every test message deleted afterwards and checked gone in WhatsApp for
Mac's database.

### WhatsApp for Mac's window through Accessibility (unlocked)

- The research of 2026-11-02 ("System Events saw zero elements") no longer holds: this version
  shows its whole window to Accessibility, with WhatsApp behind other windows. Chats are
  `AXButton`s named for the chat (", 3 unread messages" after a comma); the open chat is the
  `AXGroup` "Messages in chat with <name>" (the Owner's own chat: "You"); each message is an
  `AXStaticText` labelled with its side, words, date, and time: "Your message, <text>, November 4,
  at 21:22, Sent to You, Red", "Your photo, <caption>, …", "Your document, check.txt, …". Every
  label starts with an invisible direction mark (U+200E). The app's name is "‎WhatsApp" (with the
  mark), so looking it up by the name "WhatsApp" fails; Latchkey uses its bundle id.
- A message's `AXShowMenu` opens WhatsApp's own message menu in the background: Reply, React,
  Star, Pin, Forward, Copy, Info, Delete, Select messages. A chat row's opens the chat menu
  (Close Chat … Clear chat, Delete chat): never `AXShowMenu` on a row (one was opened by
  mistake and closed with Escape, nothing chosen).
- Delete, all in the background, WhatsApp never in front: Delete in the message menu puts the
  chat in selection mode with that message selected ("1 Selected"); `AXPress` on other bubbles
  selects them too (a bubble scrolled half out of view ignores the press until
  `AXScrollToVisible`); the bar's Delete button asks "Delete 7 for me". This deleted the seven
  test messages of 2026-11-04 (the first cleanup); the database showed them gone at once.
- Pressing a chat row (`AXPress`) opens it in the background.
- The menu bar is there too (Chat → Send, Send file…, Reply to Last Message, React to Last
  Message; Edit → Paste), but Paste is disabled while WhatsApp isn't the active app.
- Typing in the background does not work: key and text events sent to WhatsApp's process alone
  (`CGEvent.postToPid`, as the computer tools do for other apps) never reach its search field or
  message box. Setting the message box's `AXValue` shows the text but WhatsApp doesn't take it:
  the microphone stays, Send (menu) does nothing.

- Unlocked again (18:10 to 18:40), in the Owner's own chat, every message deleted afterwards and
  checked gone in the database and in WhatsApp Web's search:
  - `AXSelectedText` in the background: accepted, but the box stays empty. Not usable.
  - `whatsapp://send?phone=<number>&text=<text>`, opened without activating: WhatsApp stays
    behind, fills the box its own way, and shows Send; pressing Send (`AXPress`) sent it. The whole
    send of text to a person, or to the Owner's own chat, happens in the background.
  - Opening a message's menu (`AXShowMenu`) brings WhatsApp to the front by itself. So React,
    Reply, and Delete take the front for a moment, whatever else is done.
  - With WhatsApp in front, keys sent to its process alone still don't arrive; keystrokes through
    the session's event stream do, and so does Command-V there with a file on the clipboard (it
    opens WhatsApp's preview with a caption field and Send). Edit → Paste from the menu bar stayed
    disabled even in front. Typing into the caption field didn't arrive; the text goes as its own
    message after the file.
  - From a command-line program, `activate()`, Launch Services, and `AXFrontmost` were all granted
    only after the program ended (cooperative activation); `NSWorkspace.frontmostApplication` also
    lagged there, while the app's own `AXFrontmost` attribute told the truth at once. Latchkey (an
    app) brings Notes forward with `activate()`; WhatsApp gets `activate()`, `AXFrontmost`, and,
    failing those, its latest message's menu (opened and closed), which reliably brings it forward.
  - Bringing the Owner's app back right after pressing a reaction made WhatsApp drop it; a press
    during the reaction tray's opening animation was dropped too. Latchkey waits for what it
    pressed to go away and a moment more.
  - React: the tray shows twelve reactions (`AXIdentifier` ReactionsTray_ReactionButton), the
    Owner's own marked `AXSelected`; pressing it again takes it off. A reaction made in WhatsApp
    for Mac did not show in its database (`ZWAMESSAGEINFO` unchanged), unlike one made through
    WhatsApp Web; the chat list's line "You reacted 👍 to "<words>"" did, and is the confirmation.
  - Reply: the message box shows "Quoted message, Your message, <words>"; the reply's bubble is
    labelled "Replying to You.\n<its line>.\nQuoted message.\n<quoted words>"; the database keeps
    the quoted message's id in the reply's `ZWAMEDIAITEM.ZMETADATA`, which confirms the quote.
  - Delete: in the Owner's own chat WhatsApp offers only "Delete for me" (as WhatsApp Web's own
    check said); a selected text bubble's value is "Selected", a document's isn't.
  - Chat → Close Chat (menu bar) works in the background and leaves no chat open; Escape sent to
    WhatsApp closes the open chat (and only reached it while in front). The Archived button and
    the sidebar's Chats switch lists in the background.
  - A document sent from WhatsApp for Mac is stored with its name without the extension as text and
    no title; its bubble shows the full file name.
- Not tried live: a group or a person without a known number (pressing their row would mark the
  chat read in Toni's real chats; the steps are the ones checked in the Owner's own chat), the lid
  closed while unlocked.

### WhatsApp for Mac with the Mac locked

- Locked, WhatsApp for Mac shows Accessibility nothing but its menu bar: its one "window" is
  itself (a loop) with no chats or messages. Opening `whatsapp://send?phone=<own number>&text=…`
  in the background, then Chat → Send from the menu bar, then Return sent to its process: nothing
  was sent (database checked). So WhatsApp for Mac can't send, react, or delete while the Mac is
  locked, by any route tried; the answer says so at once (FR-1249).
- Its database stays current while locked (it showed a message sent through Safari within
  seconds), so reading keeps working.

### WhatsApp Web in Safari while locked (2026-11-05)

- With the Mac locked (14:15), the installed Latchkey opened WhatsApp Web in a background Safari
  tab and sent to the Owner's own chat; Safari answered `do JavaScript` throughout. This answers
  the open question of 2026-11-04 for this lock (spec 005 saw Safari stop answering on
  2026-11-01; it can still happen and is answered as before).
- Checked live in that tab, locked, with the new bridge: `me` found the Owner's own chat through
  `WAWebUserPrefsMeUser`; message keys (`id.id`) equal WhatsApp for Mac's `ZSTANZAID`, so one
  message id works on both paths; a reply quoted the message, as text and as a file
  (`sendTextMsgToChat(chat, text, {quotedMsg})` and the media send's `quotedMsg` option: WhatsApp
  calls `quotedMsg.msgContextInfo` itself, so passing the result of `msgContextInfo` failed with
  "T.msgContextInfo is not a function"); `WAWebSendReactionMsgAction.sendReactionToMsg(msg, "👍")`
  reacted and `""` took it off (WhatsApp for Mac's database showed 👍 in that message's
  `ZWAMESSAGEINFO.ZRECEIPTINFO`, then not); `WAWebCmd.Cmd.sendDeleteMsgs(chat, {list, type:
  'message'}, true)` deleted for me (gone from the database within 2 s);
  `WAWebMsgActionCapability.canSenderRevokeMsg` said no to deleting a one-minute-old message for
  everyone in the Owner's own chat, so that is refused with WhatsApp's own reason. Module names
  and argument shapes follow whatsapp-web.js (Apache-2.0), `src/structures/Message.js` and
  `src/util/Injected/Utils.js` (read 2026-11-05).
- `browser_act` scripts can't reach WhatsApp Web (its Content Security Policy refuses `eval`);
  Latchkey's `do JavaScript` isn't `eval` and works.

### Confirming a change in WhatsApp for Mac's database

- A message's row (`ZWAMESSAGE.Z_OPT`) and its receipts row (`ZWAMESSAGEINFO`, where reactions
  are kept) change when WhatsApp changes that message: a reaction raised `Z_OPT` from 3 to 4 and
  added the emoji to `ZRECEIPTINFO`. Latchkey takes these as the message's stamp and confirms a
  reaction by its change, a deletion by the row going (for me) or turning type 14 (for everyone),
  and a send by a new message of the Owner's in that chat with that text.
- The Owner's own account: WhatsApp's `LID.sqlite`, table `ZWAZACCOUNT`, has one row with a
  country code (the Owner's: privacy id and number); other rows are accounts it knows by privacy
  id and number, also used to find a number for a chat filed by privacy id.
