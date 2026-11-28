# Calendar, Reminders, Contacts, Location and Maps: design

GOVERNS: `macos/App/Calendar/` `macos/App/Reminders/` `macos/App/Contacts/` `macos/App/Location/`

Spec 007's plan (migrated from `specs/007-calendar-reminders-contacts-location/plan.md`, titled "Plan 007: Calendar, Reminders, Contacts, Location and Maps — HOW"). What it must do:
[requirements/calendar-reminders-contacts-location.md](../requirements/calendar-reminders-contacts-location.md). Each decision Dn is an ADR, linked
where the decision stood.

Derived from `docs/requirements/calendar-reminders-contacts-location.md`; evidence in `docs/research/2026-10-26-calendar-reminders-contacts-location.md`. Every decision names the requirements it serves.

## D1. Tools Claude sees

Decision record: [ADR 0083](../adr/0083-tools-claude-sees.md).

## D2. Calendar and Reminders: EventKit (FR-701 to FR-712, FR-744)

Decision record: [ADR 0084](../adr/0084-calendar-and-reminders-eventkit.md).

## D7. Reminders' flags, tags, subtasks, and sections (FR-714 to FR-719)

Decision record: [ADR 0085](../adr/0085-reminders-flags-tags-subtasks-and-sections.md).

## D3. Contacts (FR-721, FR-722, FR-745)

Decision record: [ADR 0086](../adr/0086-contacts.md).

## D4. Location and Maps (FR-731 to FR-734)

Decision record: [ADR 0087](../adr/0087-location-and-maps.md).

## D5. Capabilities, levels, permissions, setup (FR-741, FR-742)

Decision record: [ADR 0088](../adr/0088-capabilities-levels-permissions-setup.md).

## D6. Visibility (FR-743, FR-746)

Decision record: [ADR 0089](../adr/0089-visibility.md).

## D7. Invitations: answers, invitees, others' events (FR-705 to FR-708; 2026-11-05)

Decision record: [ADR 0090](../adr/0090-invitations-answers-invitees-others-events.md).

## Testing (Constitution VII)

- Tests first, against in-memory backends: tool names, levels and annotations (23 tools; Read
  only and Off hide the right ones), every action's routing and messages (a reminder list is
  deleted only with its right count; groups created, renamed, deleted, members added and
  removed), date parsing and
  formatting with offsets and all-day dates, free-time computation, repeat rules, event ids,
  contact matching by phone digits, a card's and a group's id changing after the create, iCloud's
  copies deleted (at once, a moment later, at the next change) and the Owner's look-alike cards
  and same-named groups left alone (FR-724 to FR-727), permission-missing answers, `maps_find` argument rules.
- Real frameworks: a test checks that `EKRecurrenceRule` and `CNMutableContact` are built as
  intended without saving. The EventKit, Contacts, Core Location, and MapKit backends are checked
  live through the hosted relay with a fresh Claude Code session: create, read, move, and delete
  a test event; create, complete, and delete a test reminder; create, read, and delete a test
  contact; the Mac's location; a place search and a drive time.

## Constitution check

| Principle | Result |
|---|---|
| I. No inbound connections | Pass: same outbound connection |
| II. Fail fast | Pass: every tool has a deadline; no prompt at call time |
| III. Disabled means nonexistent | Pass: levels filter the tools (registry) |
| IV. Good macOS citizen | Pass, with one exception approved 2026-11-05 (recorded under principle IV in the constitution): invitations (D7) use EventKit methods Apple doesn't document, because no public API exists for them (Apple: "you can't add participants to an event nor change participant information"); they are the calls Calendar itself makes, inside the public EventKit framework, with no private framework loaded, each checked before use and read back after; Reminders' flags, tags, subtasks, and sections through the Accessibility permission Latchkey already has (no private framework, no writing another app's data) |
| V. Self-hostable | Pass: no new service; MapKit is part of macOS |
| VI. Store the minimum | Pass: nothing stored on disk; ids are derived; what Latchkey created in Contacts is kept in memory for the run only (FR-724); Reminders' database is read per call, nothing kept |
| VII. Test-first | Pass: tests above written first |
| VIII. Simplicity | Pass: Apple frameworks, no dependencies |
| IX. Open source | Pass |
