# 0097. Writing by scripting, the text in a signature for a moment (FR-841 to FR-845, 2026-11-05)

- Status: accepted
- Date: 2026-11-05
- Alias: plan 008 D6a (`specs/008-mail/plan.md`, "D6a. Writing by scripting, the text in a signature for a moment (FR-841 to FR-845, 2026-11-05)")

## Context and problem

Decision D6a of spec 008's plan (Mail); requirements in
[requirements/mail.md](../requirements/mail.md). Requirement IDs it cites: none current.
The design it belongs to: [design/mail.md](../design/mail.md).

## Decision


Reverses D6's "Mail's scripting never composes" for messages without attachments (research
"Writing while locked"). Text set as an outgoing message's `content` arrives quoted; text that
Mail itself puts in as a **signature** arrives as ordinary text, above Mail's quote in a reply or
forward, with Mail's own threading headers (checked live, unlocked, 2026-11-05). Needs no window,
so it works locked, with the lid closed, and without Accessibility; Mail never comes forward.

- Routing (`MailWrite.compose`): no files → `MailSignatureWriter` always. Files and Mail's window
  usable (`ComposeWindows.unavailable()` is nil) → the window (D6, FR-842). Files and the window
  unusable: a new message → `MailSignatureWriter`, the answer saying the files are above the text;
  a reply or forward → refused before anything is made, naming sending without the file, a new
  message with the file, or `mail_queue` (FR-843, FR-835).
- `MailSignatureWriter.makeScript` (one script run): removes signatures named `Latchkey message …`
  left by a cut-off write; makes the message (`make new outgoing message … visible:false`, or
  `reply`/`forward` of the exact message by account, mailbox, and id, `opening window false`);
  prints Mail's own recipients; sets the sender; adds recipients; makes the signature (a fresh
  UUID name, `content` the text), sets it as the message's signature, waits 1 s; attaches files
  (new messages only); deletes the signature (the message keeps the text: checked live); prints
  the id, subject, From, and recipients. Any error removes the signature and closes the message.
- Swift checks (FR-844): Mail's own recipients against the original (`checkPrefill`, as D6 step
  2: the place is exact, so the Message-ID count of D6 isn't needed), then subject, From, and every
  recipient (`MailCompose.check`, `content: false`: text and files can't be read back by
  scripting). Any difference: `finishScript close`, nothing sent. Cancelled meanwhile: closed.
- `finishScript send` or `save` (save waits 3 s before closing, as D6). A failure at send is
  "Mail may not have sent it" (`afterSend`), never resent (FR-823, FR-838). Then D7.
- One write at a time (`ComposeQueue`), so two signatures never meet. Env `byScript` (true in the
  app; the window tests set it false).
- Window route fix (docs/use-cases.md, forward of 2026-11-04, "To field has the account owner's full name, which
  wasn't asked for"): Mail was slow to turn the typed address into a token, so it was typed again
  and showed twice; `MailCompose.pair` no longer counts an exact address repeated after it was
  paired with an asked address as another recipient. A repeated name still counts (two people can
  share a name; security review 2026-11-05), so a name shown twice is still refused. Such forwards
  now go by scripting anyway, which reads addresses.
- Known limits: a reply's text goes above the quote only while Mail's "Place signature above
  quoted text" is on (Mail's default; no scripting property reads it); a new message's text
  starts after one empty line; with files written by scripting, a plain-text reader sees an
  object character where the files are; a draft's plain part is empty until Mail sends it (Mail
  rebuilds it); signatures sync through iCloud, so another Mac may see one for about a second;
  an Owner's default signature isn't added (the message's signature is Latchkey's).
- Checked by `macos/scripts/mail-check.sh <to> script` (new, draft, reply, forward; each sent copy
  read back unquoted; everything swept to the Trash) and the screen-state cases
  `mail.*_locked` / `mail.*_lid` for the coordinator.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
