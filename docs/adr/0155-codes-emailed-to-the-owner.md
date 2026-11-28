# 0155. Codes emailed to the Owner (FR-1364 to FR-1367)

- Status: accepted
- Date: 2026-11-21
- Alias: plan 013 D12 (`specs/013-sign-in/plan.md`, "D12. Codes emailed to the Owner (FR-1364 to FR-1367)")

## Context and problem

Decision D12 of spec 013's plan (Signing in); requirements in
[requirements/sign-in.md](../requirements/sign-in.md). Requirement IDs it cites: none current.
The design it belongs to: [design/sign-in.md](../design/sign-in.md).

## Decision


`logins_sign_in` takes `code` (what Claude read in the Owner's email with its own tool) and
`no_email_access` (Claude has no email tool). Without either, a call waits 20 s for a text, then
asks Claude whether it can read the Owner's email: with a tool, Claude passes `code`; without,
`no_email_access`, and `MailCodes` starts Mail hidden (`NSWorkspace`, `activates` false, `hides`
true) and reads its index (`~/Library/Mail/V<n>/MailData/Envelope Index`: emails received since
the request, not in sent, draft, deleted, or trash mailboxes) and each email's own file
(`<account>/<mailbox>.mbox/<store>/Data/<id/1000's digits reversed>/Messages/<id>.emlx`; its
plain-text parts, else its HTML without head, styles, scripts, and tags; base64 and
quoted-printable decoded), because Mail's summary comes hours late (1 of 35 emails of the last
12 hours had one, 2026-11-21). Options weighed: Mail's scripting to read (needs Mail running and
froze behind the lock) vs its files (Full Disk Access, which Latchkey has, works locked); the
files chosen. After a sign-in that worked, the email (by Mail's id, account id, and mailbox name)
joins D11's list and is marked read and moved to the account's "Archive", "All Mail", or
"[Gmail]/All Mail" mailbox by an AppleScript run through `OSAScriptRunner` (which never shows a
permission question), while unlocked. For a code Claude passed, Mail's index is searched (never
started) for an email of the last 10 minutes holding that exact code, archived the same way;
without one, the answer asks Claude to archive it with its tool.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
