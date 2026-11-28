# 0086. Contacts (FR-721, FR-722, FR-745)

- Status: accepted
- Date: 2026-10-26
- Alias: plan 007 D3 (`specs/007-calendar-reminders-contacts-location/plan.md`, "D3. Contacts (FR-721, FR-722, FR-745)")

## Context and problem

Decision D3 of spec 007's plan (Calendar, Reminders, Contacts, Location and Maps); requirements in
[requirements/calendar-reminders-contacts-location.md](../requirements/calendar-reminders-contacts-location.md). Requirement IDs it cites: FR-721, FR-722, FR-745, FR-723, FR-724, FR-727.
The design it belongs to: [design/calendar-reminders-contacts-location.md](../design/calendar-reminders-contacts-location.md).

## Decision


- `ContactsBackend` with `ContactCard` values; the real one uses `CNContactStore`
  (`unifiedContacts(matching:)` for names, enumeration for emails and phone digits,
  `CNSaveRequest` for changes in the default container). Groups (FR-723): `CNMutableGroup` with
  `CNSaveRequest.add(_:toContainerWithIdentifier:)`, `update`, `delete`, `addMember(_:to:)`,
  and `removeMember(_:from:)`.
- Ids that change (FR-724 to FR-727; research.md "Ids that change"): `ContactsMemory`, shared by
  `contacts_find` and `contacts_change`, keeps in memory, for this run of the app only, each card
  and group Latchkey created: every id it had, the fingerprint of each version Latchkey wrote
  (a group: each name it gave), the ids of cards or groups that already looked the same just
  before (never matched), the cards Latchkey put in a group, and when it was made. An unknown id
  that is one of these is found again by fingerprint or name, only when exactly one fits; the
  answer says the new id. After deleting one of these within 10 minutes of its create, the tool
  deletes iCloud's copies (looking a second time 2 seconds later when the create was under 2
  minutes ago), and each later `contacts_change` within the 10 minutes first deletes copies that
  came back. `ContactsBackend.memberIDs(groupID:)` lists a group's cards for the group check.
- Calendar and Reminders keep plain EventKit ids: live checks created, moved, and deleted events
  and reminders by the ids they were given, and an event moved to another calendar is answered
  with its new id (research.md "Ids that change").
- The note field is not fetched (needs Apple's special entitlement; research.md).
- Messages' `ContactBook` (spec 002 D4) stays as it is and keeps reading Contacts whenever macOS
  allows it, whatever the Contacts level (FR-745). After a change, `ContactBook` is told to
  reload, so Messages sees new names at once.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/ContactsPlacesTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
