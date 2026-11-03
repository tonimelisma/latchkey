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
- **Photos: not working yet.** While locked the page gets no animation frames at all (unlocked,
  off-screen: it does). Unlocked or locked, a picture put in the file input opens WhatsApp's
  preview, but neither a script click on its Send button, Enter in the message box, nor a native
  mouse event delivered to the web view sends it; the preview's controls lie outside the page's
  width (x 1387 of 1200, x 1935 of 1680). Next to try: WhatsApp Web's own media functions
  (`WAWebMediaPrep` exists; `whatsapp-web.js` sends media this way), or a page that is drawn.
- **Snapshots** of the page are blank while the Mac is locked (nothing is drawn).
- Running overnight (started 21:27): heartbeat every 30 s, a text to the own chat every 2 hours;
  at 11:00 on 2026-11-03 the test logs itself out, deletes itself, and leaves its logs in
  `~/Library/Caches/walink-poc-results/` to be read into this file.
- Not yet tested: the lid closed; many hours idle; the phone offline for long.

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
