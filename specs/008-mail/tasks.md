# Tasks 008: Mail

From `plan.md`. `[P]` = parallel-safe.

- **T801** ✅ Live check: does text set by Mail's scripting arrive marked as quoted on macOS 27?
  One test message to Toni's own address; result in `research.md`. *Spec edge case, D6.*
- **T802** ✅ Add MimeFoundation to `project.yml`, pinned by commit. *D2.*
- **T803** ✅ Tests first, then the fixture (`Tests/MailFixture.swift`): a generated Envelope Index
  with the real tables and columns and `.emlx` files (plain, HTML-only, multipart with an image
  and a PDF, partial with a downloaded and a missing attachment, Gmail labels). *D2.*
- **T804** ✅ Tests first, then `MailStore`: layout check, accounts and mailboxes, find filters and
  paging, labels, message files and paths, MIME text and attachments, text search with its time
  limit, the Sent copy lookup. *FR-801 to FR-803, FR-807, FR-834, D2 to D5.*
- **T805** ✅ [P] Tests first, then `mail_find` and `mail_read` (marking, paging, attachments as
  image, text, or name, not-on-the-Mac answers, conversation). *FR-801 to FR-807, D1, D5, D9.*
- **T806** ✅ [P] Tests first (stand-in script runner), then `mail_change`: every action's script
  arguments, several ids, delete to Trash, drafts, activity. *FR-810, FR-811, FR-821, FR-832, D6.*
- **T807** ✅ Tests first, then `mail_send`: sender checks, reply quote, forward with attachments,
  confirmation in Sent, unconfirmed answer, never resent. *FR-820, FR-822 to FR-824, D6, D7.*
- **T808** ✅ Registry, levels (`mark_read` only at Read & write), setup step and Permissions row for
  Automation of Mail, Full Disk Access check, script syntax tests. *FR-830, FR-833, D8.*
- **T809** Install and live check through the hosted relay (parent session; Toni's approval for
  any send). *SC-801 to SC-804.*
- **T810** ✅ Tests first (stand-ins for Mail's windows and the clipboard; nothing opened, shown,
  or sent), then writing in Mail's compose window (Toni, 2026-10-30): new message, reply, reply
  all, forward, draft; screen off or no Accessibility refused; every field checked before Send.
  *FR-820 to FR-823, D6.*
- **T811** ✅ Security review 2026-10-30, tests first: a copied Message-ID refused and the
  response window compared with the original; recipients exactly the request (before and after
  adding); text through Accessibility and the clipboard only lent (marked, given back, change
  count checked); no window left open after a failure, even when cancelled. *D6.*
- **T812** Live check of writing in Mail's window, on Toni's Mac with the screen on and his OK
  (parent session): a new message, a reply, a forward with a file, and a draft to his own
  address; the Accessibility parts (selected text in the body and the token fields, the From
  pop-up, Save, Mail's alerts) are untested until then. *SC-801 to SC-804.*
- **T813** [x] Mail held by its own alert (2026-11-02): when a Mail script times out, Latchkey
  reads Mail's alert, presses it when it has one button, and otherwise names it and its buttons
  for someone at the Mac (`mailsAlertIsReportedWhenMailDoesNotAnswer`). *FR-839, D11.*
- **T814** [x] Writing while locked (2026-11-05), tests first (`MailSignatureWriteTests`): messages
  without files written by Mail's scripting, the text in a temporary signature; files in the window
  while it can be used, else a new message by scripting and a reply or forward refused naming the
  queue; every recipient checked before Send; the signature removed on every path; an exact address
  shown twice in the window isn't a stranger, a repeated name still is. Live: `mail-check.sh <to> script` unlocked; locked and lid
  closed by the screen-state cases (`mail.send`, `mail.reply`, `mail.forward`, `mail.draft`,
  `mail.send_file`, `mail.reply_file`). *FR-835, FR-841 to FR-845, D6a.*
