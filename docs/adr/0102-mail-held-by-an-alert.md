# 0102. Mail held by an alert (FR-839)

- Status: accepted
- Date: 2026-11-02
- Alias: plan 008 D11 (`specs/008-mail/plan.md`, "D11. Mail held by an alert (FR-839)")

## Context and problem

Decision D11 of spec 008's plan (Mail); requirements in
[requirements/mail.md](../requirements/mail.md). Requirement IDs it cites: none current.
The design it belongs to: [design/mail.md](../design/mail.md).

## Decision


Mail's app-modal alerts (seen 2026-11-01, with the lid closed: "The message … could not be moved
to the mailbox … Invalid base64 string for MIME content", Mail failing to save its own sent copy
to Exchange after the message was delivered) block every script until answered, and Mail keeps
answering Accessibility meanwhile. So when a Mail script times out (`MailCapability.run`, which
every Mail tool and the queue go through), `AXMailWindows.alert()` looks at Mail's windows, only
if Mail is running and Accessibility is on: the first `AXDialog`/`AXSystemDialog` window, or a
sheet on a window that isn't a compose window (a compose window's sheets are D6's). Pressed only
when it is an alert window (a sheet is only named) whose one control, anywhere inside it, is its
default button (no text field, checkbox, pop-up; 0.8.88, security review), since such an alert only informs; the answer says what it said and to try
again, and `alsoDone` notifies the Owner. More buttons: a choice (it could be "Send Anyway"),
named with its buttons for someone at the Mac. Options weighed: report only (leaves Mail held
until the Owner is back, which is what happened); press any alert's default button (could
choose for the Owner); press only a lone button (chosen). Found by repeating the send: the same
file through Latchkey and through Mail's own scripting both saved their sent copy while
unlocked; Mail's failed copy had been rewritten by Mail before its upload, so the cause is in
Mail's later upload, not in what Latchkey hands it.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
