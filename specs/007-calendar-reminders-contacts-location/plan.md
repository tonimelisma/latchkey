# Plan 007: Calendar, Reminders, Contacts, Location and Maps — HOW

Derived from `spec.md`; evidence in `research.md`. Every decision names the requirements it serves.

## D1. Tools Claude sees

Two tools per capability, in the find/change pattern of the other capabilities (Toni,
2026-10-23); 8 new tools, 23 in all. Location & Maps has no changes, so its two tools are both
read-only.

| Tool | Level | readOnly | destructive | Serves |
|---|---|---|---|---|
| `calendar_find` (id?, query?, from?, to?, calendar?, free?, minutes?, hours?, limit?) | Read only | yes | no | FR-701, FR-702 |
| `calendar_change` (action: create, update, delete; id, title, start, end, all_day, calendar, location, notes, url, alarms, repeat, repeat_every, repeat_until, repeat_count, span) | Read & write | no | yes | FR-703, FR-704 |
| `reminders_find` (id?, query?, list?, completed?, from?, to?, limit?) | Read only | yes | no | FR-711 |
| `reminders_change` (action: create, update, complete, uncomplete, delete, create_list; id, title, notes, list, due, priority, url, alarms, repeat, repeat_every, repeat_until, repeat_count) | Read & write | no | yes | FR-712 |
| `contacts_find` (id?, query?, group?, photo?, limit?) | Read only | yes | no | FR-721 |
| `contacts_change` (action: create, update, delete; id, given_name, family_name, middle_name, nickname, organization, job_title, department, phones, emails, addresses, birthday, urls) | Read & write | no | yes | FR-722 |
| `location_read` () | On | yes | no | FR-731 |
| `maps_find` (query?, near?, to?, from?, mode?, depart_at?, arrive_by?, address?, limit?) | On | yes | no | FR-732 to FR-734 |

- `calendar_find`: with `id`, the one event in full. With `free`, free times of at least
  `minutes` (default 30) in the range, within `hours` (default `08:00-20:00`). With nothing, the
  calendars and the next 7 days. Otherwise events from `from` (default the start of today) to
  `to` (default 7 days later, or 30 with a query), matching `query` (title, location, notes) and
  `calendar` (name or id).
- `reminders_find`: with `id`, one reminder. With nothing, the lists with open counts, then open
  reminders (overdue and dated first, then undated). `completed: true` lists completed ones from
  `from` (default 30 days ago) to `to` (default now).
- `contacts_find`: with `id`, the card (with `photo`, its picture as an image). With nothing,
  the groups and the number of contacts. Otherwise cards matching `query` in names, nickname,
  company, emails, and phone digits, and `group`.
- `maps_find`: `query` searches places near `near` (address, `lat,lon`, or `here`; default the
  Mac when Location is allowed); `to` gives directions from `from` (default `here`) by `mode`
  (`driving` default, `walking`, `transit`); `address` alone geocodes it (or reverse-geocodes
  `lat,lon`). Exactly one of `query`, `to`, `address` is given; otherwise the tool says so.
- Lists in arguments are JSON arrays: `alarms` minutes before (`[10, 60]`), `phones` and
  `emails` `[{"label": "mobile", "value": "…"}]`, `addresses` `[{"label", "street", "city",
  "state", "postal_code", "country"}]`, `urls` strings. `repeat` is `daily`, `weekly`,
  `monthly`, `yearly`, or `none`; `span` is `this` (default) or `future`; `priority` is `none`,
  `low`, `medium`, `high`.
- Deadlines (`latchkey/deadline_ms`): finds 15 s, changes 15 s, `location_read` 15 s,
  `maps_find` 20 s (network).
- Results are text (as all tools, `.claude/rules/macos.md`), paged at `ResultLimit` like the
  others, with ids Claude passes back.

## D2. Calendar and Reminders: EventKit (FR-701 to FR-712, FR-744)

- One `EKEventStore` for the app, behind `EventsBackend` (protocol with value types
  `CalendarInfo`, `EventInfo`, `EventDraft`, `ReminderInfo`, `ReminderDraft`). The store is
  used from one serial queue (it isn't thread-safe).
- Events in a range: `predicateForEvents(withStart:end:calendars:)`, which expands repeats;
  ranges over 4 years are refused with a message. Ids per research.md ("Event ids").
- Changes: `save(_:span:commit:)` and `remove(_:span:commit:)` with `.thisEvent` or
  `.futureEvents`. New events go to the named calendar or the default one; a calendar that
  doesn't allow changes (`allowsContentModifications` false) or an event with attendees the
  Owner doesn't organize is refused with the FR-704 message before saving. Any `invitees`-like
  wish is answered by the tool description: invitations can't be sent.
- Repeats: `EKRecurrenceRule(recurrenceWith:interval:end:)`, end by date or count.
- Reminders: `predicateForIncompleteReminders` / `predicateForCompletedReminders`, fetched with
  the callback API wrapped in a continuation with the tool's deadline. Due dates: a date only
  sets `dueDateComponents` without a time; a date-time sets both. Priority maps none 0, high 1,
  medium 5, low 9 (Apple's values). `create_list` makes an `EKCalendar(for: .reminder)` in the
  default reminders source.
- Free time (FR-702): busy intervals merged, then the gaps of at least `minutes` inside each
  day's `hours`, per research.md.
- Dates (FR-744): one parser and one formatter (`CalendarDates`), research.md "Dates in and
  out". Every answer starts with `Times are in <zone> (UTC±hh:mm).`

## D3. Contacts (FR-721, FR-722, FR-745)

- `ContactsBackend` with `ContactCard` values; the real one uses `CNContactStore`
  (`unifiedContacts(matching:)` for names, enumeration for emails and phone digits,
  `CNSaveRequest` for changes in the default container).
- The note field is not fetched (needs Apple's special entitlement; research.md).
- Messages' `ContactBook` (spec 002 D4) stays as it is and keeps reading Contacts whenever macOS
  allows it, whatever the Contacts level (FR-745). After a change, `ContactBook` is told to
  reload, so Messages sees new names at once.

## D4. Location and Maps (FR-731 to FR-734)

- `PlacesBackend`; the real one: Core Location for the fix (research.md "Location fix"),
  `MKReverseGeocodingRequest` for its address, `MKLocalSearch` (region of 20 km around the
  centre), `MKDirections.calculate()` for driving and walking (distance, time, steps),
  `calculateETA()` for transit (time, departure and arrival), `MKGeocodingRequest`.
- `here` with Location not allowed or Location Services off answers what to turn on, and the
  other inputs keep working.

## D5. Capabilities, levels, permissions, setup (FR-741, FR-742)

- Registry ids `calendar`, `reminders`, `contacts`, `location`; defaults `readWrite` (FR-741).
  Location uses levels Off/On like Shell (`onTitle: "On"`), its tools in `readTools`.
- Settings window: the four appear in the capability list with their summaries.
- Permissions tab rows: Calendars, Reminders, Location (needed when their capability is on);
  Contacts becomes needed when the Contacts capability is on, and stays optional for Messages
  otherwise (FR-745).
- Setup window steps, shown while the capability is on and the permission is missing: "Let
  Claude see your calendars", "Let Claude see your reminders", "Let Claude see your contacts"
  (replaces "Show names in Messages" when Contacts is on), "Let Claude see where this Mac is".
  Each asks macOS once (Continue); after a refusal it opens the right System Settings page.
- A tool called without permission answers at once (FR-742, SC-704).
- Info.plist usage strings and entitlements per research.md "Permissions".

## D6. Visibility (FR-743, FR-746)

- Each change returns an `activity` ("Claude added “Dentist” to Home", "Claude completed “Buy
  milk”", "Claude deleted the contact “Test Person”"), which becomes the notification (spec 002
  D8) and appears in the log.
- The menu's activity names the new capabilities (Calendar, Reminders, Contacts, Location,
  Maps).
- Notes and titles of events organized by someone else, and attendee names, are wrapped as
  text written by others (spec 002 D6).

## Testing (Constitution VII)

- Tests first, against in-memory backends: tool names, levels and annotations (23 tools; Read
  only and Off hide the right ones), every action's routing and messages, date parsing and
  formatting with offsets and all-day dates, free-time computation, repeat rules, event ids,
  contact matching by phone digits, permission-missing answers, `maps_find` argument rules.
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
| IV. Good macOS citizen | Pass: public frameworks and standard prompts only |
| V. Self-hostable | Pass: no new service; MapKit is part of macOS |
| VI. Store the minimum | Pass: nothing stored; ids are derived |
| VII. Test-first | Pass: tests above written first |
| VIII. Simplicity | Pass: Apple frameworks, no dependencies |
| IX. Open source | Pass |
