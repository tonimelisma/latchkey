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
- Not yet tested: the lid closed; hours of idle with the page kept open; what the page does when
  the phone has been offline for a long time; sending to a group, a file, or a photo; reading
  from the page.

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
