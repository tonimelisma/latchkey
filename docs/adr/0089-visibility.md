# 0089. Visibility (FR-743, FR-746)

- Status: accepted
- Date: 2026-10-26
- Alias: plan 007 D6 (`specs/007-calendar-reminders-contacts-location/plan.md`, "D6. Visibility (FR-743, FR-746)")

## Context and problem

Decision D6 of spec 007's plan (Calendar, Reminders, Contacts, Location and Maps); requirements in
[requirements/calendar-reminders-contacts-location.md](../requirements/calendar-reminders-contacts-location.md). Requirement IDs it cites: FR-743, FR-746.
The design it belongs to: [design/calendar-reminders-contacts-location.md](../design/calendar-reminders-contacts-location.md).

## Decision


- Each change returns an `activity` ("Claude added “Dentist” to Home", "Claude completed “Buy
  milk”", "Claude deleted the contact “Test Person”"), which becomes the notification (spec 002
  D8) and appears in the log.
- The menu's activity names the new capabilities (Calendar, Reminders, Contacts, Location,
  Maps).
- Notes and titles of events organized by someone else, and attendee names, are wrapped as
  text written by others (spec 002 D6).

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
