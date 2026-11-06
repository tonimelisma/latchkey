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
| `reminders_find` (id?, query?, list?, completed?, from?, to?, limit?) | Read only | yes | no | FR-711, FR-714 |
| `reminders_change` (action: create, update, complete, uncomplete, delete, create_list, delete_list; id, title, notes, list, due, priority, url, alarms, repeat, repeat_every, repeat_until, repeat_count, reminder_count, flagged, tags, parent, section) | Read & write | no | yes | FR-712, FR-713, FR-715 to FR-719 |
| `contacts_find` (id?, query?, group?, photo?, limit?) | Read only | yes | no | FR-721 |
| `contacts_change` (action: create, update, delete, create_group, rename_group, delete_group, add_to_group, remove_from_group; id, ids, group, name, given_name, family_name, middle_name, nickname, organization, job_title, department, phones, emails, addresses, birthday, urls) | Read & write | no | yes | FR-722, FR-723 |
| `location_read` () | On | yes | no | FR-731 |
| `maps_find` (query?, near?, to?, from?, mode?, depart_at?, arrive_by?, address?, limit?) | On | yes | no | FR-732 to FR-734 |

- `calendar_find`: with `id`, the one event in full. With `free`, free times of at least
  `minutes` (default 30) in the range, within `hours` (default `08:00-20:00`). With nothing, the
  calendars and the next 7 days. Otherwise events from `from` (default the start of today) to
  `to` (default 7 days later, or 30 with a query), matching `query` (title, location, notes) and
  `calendar` (name or id).
- `reminders_find`: with `id`, one reminder. With nothing, the lists with open counts, then open
  reminders (overdue and dated first, then undated). `completed: true` lists completed ones from
  `from` (default 30 days ago) to `to` (default now). With `list`, the answer starts with how
  many reminders the list holds, open and completed (FR-713).
- `reminders_change` `delete_list`: `list` (name or id) and `reminder_count`; the tool counts
  the list's open and completed reminders and deletes it only when the number matches,
  otherwise it answers with the actual number and deletes nothing (FR-713, research.md
  "Reminder lists").
- `contacts_change` groups: `create_group` (`name`), `rename_group` (`group`, `name`),
  `delete_group` (`group`; cards stay), `add_to_group` / `remove_from_group` (`group`, and `id`
  or `ids`). A name another group already has is refused (FR-723, research.md "Contact
  groups").
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
  default reminders source; `delete_list` counts with the two reminder predicates for that one
  list, then `removeCalendar(_:commit:)` (FR-713).
- Free time (FR-702): busy intervals merged, then the gaps of at least `minutes` inside each
  day's `hours`, per research.md.
- Dates (FR-744): one parser and one formatter (`CalendarDates`), research.md "Dates in and
  out". Every answer starts with `Times are in <zone> (UTC±hh:mm).`

## D7. Reminders' flags, tags, subtasks, and sections (FR-714 to FR-719)

Evidence and options in research.md "Flags, tags, subtasks, and sections". EventKit has none of
them; nothing writes Reminders' database.

- Reading (FR-714): `RemindersStore` (App/Reminders) opens each `Data-*.sqlite` in Reminders'
  group container read-only per call and returns a `RemindersSnapshot` by reminder id (the
  database's `ZCKIDENTIFIER` is EventKit's `calendarItemIdentifier`): flag, tags, parent,
  subtasks, section, image count, attached links; sections per list. `reminders_find` marks
  flagged reminders ⚑, adds `#tags` and the subtask count, puts subtasks indented under their
  reminder, matches `query` against tags, names a list's sections, and reads one reminder with
  its section, flag, tags, parent, subtasks, images, and links. No snapshot (no Full Disk
  Access): "unknown".
- Writing (FR-715 to FR-718): `RemindersWindow` (App/Reminders) drives Reminders' main window
  through Accessibility. The reminder is selected by opening `x-apple-reminderkit://REMCDReminder/<id>`
  without activating Reminders; then, on the selected row: its own actions `Indent`, `Outdent`,
  `Move Up`, `Move Down` (subtasks), the title field (tags: "#name" typed after the title, then
  the title set back through EventKit), and, with Reminders in front for a moment, Edit → Flag
  and File → Move to Section → name / None. `RemindersExtras.apply` runs parent, section,
  tags, flag in that order and checks each in the database (`saved`, up to 5 s).
- Subtasks: `ReminderRowPlan.next` moves the row until the parent (or its last subtask) is right
  above it, then indents; one level only; a reminder in another list moves to the parent's
  list first (through EventKit), and `create` with `parent` creates it in the parent's list.
- Moving lists (FR-719): a reminder that is a subtask, or has subtasks, moves through
  `EventsBackend.moveReminders` (one EventKit commit, parent and subtasks together), and the
  subtasks are put back under it in the window; a subtask is first taken out of its parent.
- Not losing anything (FR-719): every other change stays a plain EventKit save of the fields
  Claude gave, which keeps flags, tags, subtasks, attachment links, and images (checked live).
  Deleting a reminder says what happened to its subtasks.
- States (FR-719): `preflight` refuses window changes before any change while the Mac is locked
  (Reminders' window has no rows then) and when the database can't be read (nothing could be
  checked). The lid closed while unlocked is tried by the screen-state check
  (`reminders.subtask`, `reminders.keeps_extras`, `reminders.unflag_outdent`).

## D3. Contacts (FR-721, FR-722, FR-745)

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
| IV. Good macOS citizen | Pass: public frameworks and standard prompts only; Reminders' flags, tags, subtasks, and sections through the Accessibility permission Latchkey already has (no private framework, no writing another app's data) |
| V. Self-hostable | Pass: no new service; MapKit is part of macOS |
| VI. Store the minimum | Pass: nothing stored on disk; ids are derived; what Latchkey created in Contacts is kept in memory for the run only (FR-724); Reminders' database is read per call, nothing kept |
| VII. Test-first | Pass: tests above written first |
| VIII. Simplicity | Pass: Apple frameworks, no dependencies |
| IX. Open source | Pass |
