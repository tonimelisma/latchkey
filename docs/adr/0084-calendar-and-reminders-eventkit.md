# 0084. Calendar and Reminders: EventKit (FR-701 to FR-712, FR-744)

- Status: accepted
- Date: 2026-10-26
- Alias: plan 007 D2 (`specs/007-calendar-reminders-contacts-location/plan.md`, "D2. Calendar and Reminders: EventKit (FR-701 to FR-712, FR-744)")

## Context and problem

Decision D2 of spec 007's plan (Calendar, Reminders, Contacts, Location and Maps); requirements in
[requirements/calendar-reminders-contacts-location.md](../requirements/calendar-reminders-contacts-location.md). Requirement IDs it cites: FR-701, FR-712, FR-744, FR-704, FR-713, FR-702.
The design it belongs to: [design/calendar-reminders-contacts-location.md](../design/calendar-reminders-contacts-location.md).

## Decision


- One `EKEventStore` for the app, behind `EventsBackend` (protocol with value types
  `CalendarInfo`, `EventInfo`, `EventDraft`, `ReminderInfo`, `ReminderDraft`). The store is
  used from one serial queue (it isn't thread-safe).
- Events in a range: `predicateForEvents(withStart:end:calendars:)`, which expands repeats;
  ranges over 4 years are refused with a message. Ids per research.md ("Event ids").
- Changes: `save(_:span:commit:)` and `remove(_:span:commit:)` with `.thisEvent` or
  `.futureEvents`. New events go to the named calendar or the default one; a calendar that
  doesn't allow changes (`allowsContentModifications` false) is refused with the FR-704 message
  before saving. Invitations and others' events: D7 (until 2026-11-05 they were refused too).
- Repeats: `EKRecurrenceRule(recurrenceWith:interval:end:)`, end by date or count.
- Reminders: `predicateForIncompleteReminders` / `predicateForCompletedReminders`, fetched with
  the callback API wrapped in a continuation with the tool's deadline. Due dates: a date only
  sets `dueDateComponents` without a time; a date-time sets both. Priority maps none 0, high 1,
  medium 5, low 9 (Apple's values). `create_list` makes an `EKCalendar(for: .reminder)` in the
  default reminders source; `delete_list` counts with the two reminder predicates for that one
  list, then `removeCalendar(_:commit:)` (FR-713).
- Free time (FR-702): busy intervals merged, then the gaps of at least `minutes` inside each
  day's `hours`, per research.md.
- Dates (FR-744): one parser and one formatter (`CalendarDates`), research.md "Dates in and
  out". Every answer starts with `Times are in <zone> (UTC±hh:mm).`

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
