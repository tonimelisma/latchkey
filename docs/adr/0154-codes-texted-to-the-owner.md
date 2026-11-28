# 0154. Codes texted to the Owner (FR-1360, FR-1362, FR-1363)

- Status: accepted
- Date: 2026-11-22
- Alias: plan 013 D11 (`specs/013-sign-in/plan.md`, "D11. Codes texted to the Owner (FR-1360, FR-1362, FR-1363)")

## Context and problem

Decision D11 of spec 013's plan (Signing in); requirements in
[requirements/sign-in.md](../requirements/sign-in.md). Requirement IDs it cites: none current.
The design it belongs to: [design/sign-in.md](../design/sign-in.md).

## Decision


(2026-11-22: one look, no waiting; texts since the last password Latchkey typed on the site in
the last 10 minutes, else the last 10 minutes; the text deleted right after the code is typed.
FR-1361 and the delivery throttle are withdrawn.)

`TextedCodes` (App/SignIn): when `SignInFlow` reaches a code step and the sign-in has no code
generator, it asks for a texted code. Messages' database (its own read-only connection, as
`messages_find` reads) is looked at every second for texts not from the Owner that arrived
since the site's request (the first time it asked, kept for 2 minutes across calls), newest
first; the first unused one holding a code is taken. A code is a run of 4 to 8 digits standing
alone next to a word like "code", "OTP", "verification" (also Finnish and other languages'); a
text with numbers but no such word is no code text (security review 2026-11-21). A text is
queued for deleting only after the sign-in with its code succeeded, and deleted only while
Messages is Read & write. Each text id is used once (in
memory). One call waits up to 45 s (the relay allows 60 s); with no text by then the answer
asks for another call, and after 2 minutes the sign-in counts as needing a code (D10's fallback).
No text is used while Messages is Off.

After use, the text's id joins a list kept in user defaults (an id, no text), and the list is
worked through at once while the Mac is unlocked, else on the unlock notification and at start:
`CodeTextWindow.delete` opens `sms://open?message-guid=` without activating Messages, requires the
window's title to name that conversation's people (a short code must match whole), finds the one
message on the other side with that text, performs Messages' own "Delete…", answers the sheet,
and waits until Messages' database no longer lists the message. Recovered from spec 002's
withdrawn window actions (commit 6b9beb3), delete only. Each id is tried once; a failure is
logged and the text stays.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
