# Plan 012: WhatsApp — HOW

Spec: `spec.md`. Research and every test behind these choices: `research.md`. Extended
2026-11-05: replies, reactions, deleting, "me", older history (D5), and WhatsApp for Mac's window
as the fallback again (D3b). Rebuilt on
2026-11-04 after Toni chose (spec FR-1206, FR-1208, FR-1215, FR-1222): no linked device of
Latchkey's own; sending only through WhatsApp Web in Safari, opened in a tab when none is;
WhatsApp for Mac's database for reading while that app runs. The first build (0.8.101 to
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
- No WhatsApp tab (FR-1208): Latchkey opens `https://web.whatsapp.com/` at the end of Safari's
  front window without selecting it (a new window when there is none), then waits up to 25 s for
  it to connect with Safari's own login (the same linked device as the Owner's tab; nothing new
  is linked). Options weighed: answer "open WhatsApp Web" (nothing done unasked, but sending from
  away fails whenever the tab was closed), or open it (works from anywhere; a tab appears).
  Chosen by Toni: open it.

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
| Reply (2026-11-05) | `sendTextMsgToChat(chat, text, {quotedMsg: msg})`; media `sendToChat({chat, options: {quotedMsg}})` |
| React, unreact | `WAWebSendReactionMsgAction.sendReactionToMsg(msg, emoji)`, `""` to take it off |
| Delete | `WAWebCmd.Cmd.sendDeleteMsgs(chat, {list: [msg], type: 'message'}, true)`; for everyone `sendRevokeMsgs(…, {clearMedia: true})` after `WAWebMsgActionCapability.canSenderRevokeMsg(msg)` |
| The Owner's own chat | `WAWebUserPrefsMeUser.getMaybeMePnUser()` / `getMaybeMeLidUser()` |

The modules only replies, reactions, deleting, and "me" use are checked when used, so a rename
there names itself without stopping sending and reading. All of this is one JavaScript source (`WhatsAppBridge.swift`) that defines `window.__latchkey`
with a function per operation and checks that every module it needs exists; when WhatsApp
renames one, the tools say which, and that Latchkey needs an update. Message ids have no
`_serialized` (use `String(id)`); the text-send promise settled about 38 s after the message was
out (2026-11-03), so the message in the chat with `ack` ≥ 1 is the confirmation. `screen()` gives
the page's words while no chats show (a loading or sync screen), so an unusable tab's answer says
why; the log-in screen counts only while no chats show (a message's words can't fake it).

## D3 WhatsApp for Mac's window (withdrawn 2026-11-04)

Withdrawn the same day it was built and checked live (Toni): it works only with the Mac unlocked,
which is when it is least needed. What it did, for the record:

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

## D3b WhatsApp for Mac's window again, as the fallback (2026-11-05)

Serves FR-1245, FR-1246, FR-1247, FR-1249. Reverses D3's withdrawal: Toni asked for everything
missing, and a fallback that works only unlocked still beats none when Safari can't be used
(working functionality outranks the 2026-11-04 decision). Research: "2026-11-05" in research.md.

- Used only when the tab can't be used (no tab and none could be opened, Safari not answering,
  logged out, not connected, WhatsApp Web changed) and nothing went through it (FR-1216), with
  WhatsApp for Mac running and its database readable. The answer says why Safari wasn't used.
- Locked (FR-1249): WhatsApp for Mac shows Accessibility nothing but its menu bar; the answer
  says so at once. Nothing is tried.
- Everything through Accessibility, as the computer tools do (`AXPress`, `AXShowMenu`,
  `AXScrollToVisible`, `AXScrollUp/DownByPage`), with WhatsApp found by its bundle id (its name
  starts with an invisible mark). WhatsApp stays behind for opening chats, reacting, deleting,
  and replies' Reply step.
- Opening the chat with certainty (FR-1246, security review 2026-11-05): a person with a known
  number, and the Owner's own chat with the Owner's number, through WhatsApp's own link
  `whatsapp://send?phone=<digits>` opened without activating; the header must then name that
  chat ("You" for the Owner's own). A group, or a person without a known number, by its row in
  the chat list, only when no other chat in the database has that name and the whole list
  (scrolled a page at a time) shows exactly one row with it.
- The message (FR-1246): looked for only in the open chat's messages, by side ("Your …" only for
  the Owner's own), words or file name, date and time ("November 4, at 21:22"; today's carry the
  time alone), scrolling up for older ones; refused when it has no words or file name, when more
  than one bubble matches, or when the database has another message of that chat with the same
  side, words, and minute.
- Delete: the message menu's Delete, which selects it; the selection bar's Delete; then "Delete
  for me" or "Delete for everyone" in WhatsApp's own dialog. React: the message menu's React,
  then the emoji. Reply: the message menu's Reply before the text.
- Text and files. Options weighed, least intrusive first:
  1. Background only: keys and text sent to WhatsApp's process alone don't arrive; setting the
     box's `AXValue` shows text WhatsApp doesn't take (2026-11-05). `AXSelectedText` (the text
     view's own insertion, which Notes takes) is tried first for text.
  2. `whatsapp://send?phone=…&text=…`: fills the box the app's own way, but only for people with
     a number, and Send still needs a press; no groups, no files.
  3. Paste or drag files: drag needs the real pointer (rejected); Paste is disabled while
     WhatsApp isn't the active app.
  4. WhatsApp briefly in front (as Notes' tick, spec 002 D3a): Paste works for text and for files
     (each opens WhatsApp's preview, sent with Return), the Owner's clipboard is put back, and the
     app they were in comes back. Chosen when 1 doesn't take the text, and for files.
- Confirmation in WhatsApp for Mac's database (FR-1247), by the message's id: a deletion when the
  row is gone (for me) or type 14 (for everyone); a reaction when that message's stamp (its row
  version and its receipts, where reactions are kept) changed; a send when a new message of the
  Owner's with that text is in that chat. Otherwise the answer says it may or may not have
  happened (FR-1216), never retried.

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
- `whatsapp_send` (write): `to`, `text`, `files`, `reply_to` (a message id, FR-1241). One match
  is required: several give the candidates and nothing is sent (FR-1213). Through the tab (D1),
  else WhatsApp for Mac's window (D3b).
- `whatsapp_change` (write, 2026-11-05): `chat`, `message` (its id), `action` react | unreact |
  delete, `emoji`, `everyone` (FR-1242, FR-1243). Through the tab, else WhatsApp for Mac's window.
  Options weighed for the shape: separate tools per action (more names for Claude to choose
  from), or one change tool like `notes_change` and `mail_change` (chosen: the pattern the other
  capabilities use).
- Message ids (FR-1240): WhatsApp's own key for a message, `id.id` in WhatsApp Web and
  `ZSTANZAID` in WhatsApp for Mac's database (the same string, checked 2026-11-05), shown as
  `msg <id>` on every message line. Options weighed: the database's row number (only one path
  knows it), WhatsApp Web's full id (`true_<chat>_<key>_out`, long, Web only), the stanza key
  (both paths; chosen).
- "me" (FR-1244): WhatsApp Web's own idea of who is logged in (`WAWebUserPrefsMeUser`); in the
  database the one account with a country code in `LID.sqlite` (`ZWAZACCOUNT`), matched on the
  chat's id only, never on the name You (security review 2026-11-05).
- Older history (FR-1248): while reading through the tab, when it holds fewer messages than asked
  for, the rest come from WhatsApp for Mac's database (messages before the oldest one shown,
  found by chat id: `@c.us` is `@s.whatsapp.net` there, or the privacy id), marked as such.
- Reading source (FR-1222): the database while WhatsApp for Mac runs; else the tab when connected;
  else the database, saying how old its newest message is; else an answer saying neither is there.
  A chat's time and preview come from its last message (`ZLASTMESSAGE`): `ZLASTMESSAGEDATE` is a
  sort key WhatsApp moves thousands of years ahead for a pinned chat, and `ZLASTMESSAGETEXT` is
  encoded. Senders known only by privacy id (`…@lid`) get their names from WhatsApp's copy of the
  address book, `ContactsV2.sqlite`.
- After a relink WhatsApp for Mac files most person chats by privacy id (`…@lid`; 47 of 60 on
  2026-11-04). The address book's `ZLID` and `ZWHATSAPPID` give number ↔ privacy id, so a phone
  number finds such a chat, the window (D3) gets the number for one, and its confirmation looks
  under both ids (the confirmation was the withdrawn window's, D3).
- Files are checked for size and kind before they are read (security review 2026-11-03); at most
  64 MB per call; photos (`image/*`) go as photos, anything else as documents.
- Settings, WhatsApp section: one line on what WhatsApp needs on the Mac and the warning
  (FR-1232).

## D6 Deadline

Serves FR-1212. `whatsapp_send` and `whatsapp_change` declare 60 s (spec 001 FR-011's cap): 5 s to look at the tab,
up to 25 s for a tab Latchkey opened to connect, and 25 s for the send (WhatsApp's confirmation
waited for up to 20 s).

## D7 Off

Serves FR-1230. At Off the tools disappear (Constitution III); nothing is logged out (Latchkey
linked nothing). Read only removes `whatsapp_send`.

## Constitution check

- I (outbound only): nothing listens; Safari and WhatsApp for Mac make their own connections.
- II (fail fast): every Safari script has a deadline; an unusable tab or a locked Mac answers at
  once with why; every wait in WhatsApp for Mac's window is bounded (a few seconds each, 10 s
  for the database to confirm).
- III (off is invisible): Off removes the tools.
- IV (real Mac app): AppleScript, a URL scheme, and Accessibility; all Apple-supported.
- VI (relay stores no results): unchanged.
- VII (tests first): bridge contract tests run the JavaScript against a stand-in of WhatsApp's
  modules; the Safari call's JavaScript runs in a real WebKit view; tool tests use fake tab and
  window and a fixture copy of the desktop database; the live check runs against real WhatsApp.
