# 0138. Driving WhatsApp Web: its own functions, not its screen

- Status: accepted
- Date: 2026-11-04
- Alias: plan 012 D2 (`specs/012-whatsapp/plan.md`, "D2. Driving WhatsApp Web: its own functions, not its screen")

## Context and problem

Decision D2 of spec 012's plan (WhatsApp); requirements in
[requirements/whatsapp.md](../requirements/whatsapp.md). Requirement IDs it cites: FR-1220, FR-1222.
The design it belongs to: [design/whatsapp.md](../design/whatsapp.md).

## Decision


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
there names itself without stopping sending and reading. All of this is one JavaScript source (WhatsAppBridge.swift) that defines `window.__latchkey`
with a function per operation and checks that every module it needs exists; when WhatsApp
renames one, the tools say which, and that Latchkey needs an update. Message ids have no
`_serialized` (use `String(id)`); the text-send promise settled about 38 s after the message was
out (2026-11-03), so the message in the chat with `ack` ≥ 1 is the confirmation. `screen()` gives
the page's words while no chats show (a loading or sync screen), so an unusable tab's answer says
why; the log-in screen counts only while no chats show (a message's words can't fake it).

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/WhatsAppStoreTests.swift`
- `macos/Tests/WhatsAppToolsTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
