# 0087. Location and Maps (FR-731 to FR-734)

- Status: accepted
- Date: 2026-10-26
- Alias: plan 007 D4 (`specs/007-calendar-reminders-contacts-location/plan.md`, "D4. Location and Maps (FR-731 to FR-734)")

## Context and problem

Decision D4 of spec 007's plan (Calendar, Reminders, Contacts, Location and Maps); requirements in
[requirements/calendar-reminders-contacts-location.md](../requirements/calendar-reminders-contacts-location.md). Requirement IDs it cites: FR-731, FR-734.
The design it belongs to: [design/calendar-reminders-contacts-location.md](../design/calendar-reminders-contacts-location.md).

## Decision


- `PlacesBackend`; the real one: Core Location for the fix (research.md "Location fix"),
  `MKReverseGeocodingRequest` for its address, `MKLocalSearch` (region of 20 km around the
  centre), `MKDirections.calculate()` for driving and walking (distance, time, steps),
  `calculateETA()` for transit (time, departure and arrival), `MKGeocodingRequest`.
- `here` with Location not allowed or Location Services off answers what to turn on, and the
  other inputs keep working.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
