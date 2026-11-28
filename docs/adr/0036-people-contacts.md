# 0036. People: Contacts

- Status: accepted
- Date: 2026-10-21
- Alias: plan 002 D4 (`specs/002-notes-messages/plan.md`, "D4. People: Contacts")

## Context and problem

Decision D4 of spec 002's plan (Notes and Messages); requirements in
[requirements/notes-messages.md](../requirements/notes-messages.md). Requirement IDs it cites: FR-111, FR-112, FR-171.
The design it belongs to: [design/notes-messages.md](../design/notes-messages.md).

## Decision


Serves FR-111, FR-112. The Contacts framework maps phone numbers and emails to names, and names to
handles for sending. An ambiguous name (two Sarahs) returns the choices instead of guessing; one
Sarah with several numbers and no conversation gets one chosen (FR-171, D3b). Contacts access is asked for in setup ("Show names in Messages"),
never at call time; without it, messages show numbers and addresses. A number matches a contact
when one ends with the other (compared on the last 9 digits), so "+1 555…" and "(555) …" agree;
a number two contacts share gets no name.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/MessagesSendTests.swift`
- `macos/Tests/MessagesTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
