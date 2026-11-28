# 0040. Visibility on the Mac

- Status: accepted
- Date: 2026-10-21
- Alias: plan 002 D8 (`specs/002-notes-messages/plan.md`, "D8. Visibility on the Mac")

## Context and problem

Decision D8 of spec 002's plan (Notes and Messages); requirements in
[requirements/notes-messages.md](../requirements/notes-messages.md). Requirement IDs it cites: FR-130, FR-131, FR-132, FR-026.
The design it belongs to: [design/notes-messages.md](../design/notes-messages.md).

## Decision


Serves FR-130, FR-131, FR-132.
- Notifications (UserNotifications) after each send, create, update, delete: "Claude sent a message
  to Sarah", "Claude added to “Groceries”".
- The menu shows the 10 most recent activities from the local trace (FR-026), each a submenu with
  the request and result; "Show All Activity…" opens the existing window.
- While any call runs, the menu bar icon shows a small activity dot.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/MenuTests.swift`
- `macos/Tests/TraceTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
