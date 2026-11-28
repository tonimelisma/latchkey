# 0101. Queued email while the Mac is locked (FR-835 to FR-837, decided 2026-11-02)

- Status: accepted
- Date: 2026-11-02
- Alias: plan 008 D10 (`specs/008-mail/plan.md`, "D10. Queued email while the Mac is locked (FR-835 to FR-837, decided 2026-11-02)")

## Context and problem

Decision D10 of spec 008's plan (Mail); requirements in
[requirements/mail.md](../requirements/mail.md). Requirement IDs it cites: FR-661.
The design it belongs to: [design/mail.md](../design/mail.md).

## Decision


Since 2026-11-05 (D6a) only a reply or forward with attachments needs the queue while locked.
Mail's window can't be used while the session is locked (checked live 2026-11-01), and Latchkey
never gets around the lock (spec 001 FR-661). Options the maintainer was shown: refuse; queue until the
next unlock; send at once through Mail's scripting (text shows as quoted in other apps). Chosen:
a tool of its own, `mail_queue` (add with mail_send's inputs, list, cancel), so Claude decides
with the Owner whether waiting is fine; mail_send's locked answer names it. The queue
(`MailQueue`) is one JSON file in the app's support folder, mode 0600, removed when empty and
by uninstalling; ids q1, q2. On macOS's `com.apple.screenIsUnlocked` (and at start when
unlocked), while Mail is Read & write, `AppModel.sendQueuedMail` waits 3 s, then sends each
item, oldest first, through `MailWrite.send` (all of D6 and D7's checks), removing it first so
it is never sent twice, and notifies the Owner and the activity log of each result. FR-838: an
answer starting "Nothing was sent" (every check before Send, and Mail's window failing) puts the
item back in its place with a count of failed tries and the last reason; anything else (an
unconfirmed or unreadable Sent copy) drops it, since trying again could send it twice. Each round
tries each item once; a round that put one back schedules another in 300 s while unlocked
(unlock and start rounds cancel it; one round at a time). Three failed tries drop it.
Security review (2026-11-02): a failure after Send was pressed (Mail's window stayed open, or
showed a sheet) is answered "Mail may not have sent it: …", never "Nothing was sent", so the
queue drops it; and the ids of items being tried stay reserved, so one queued meanwhile can't
share an id with one put back. Low-level
choices: no expiry (a queued message waits however long the Mac stays locked; the Owner can ask
Claude to cancel it); attachments are checked when queued and again when sent.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
