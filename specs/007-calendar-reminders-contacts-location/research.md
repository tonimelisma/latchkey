# Research 007: Calendar, Reminders, Contacts, Location and Maps

Done 2026-10-26, before the spec. Sources at the end.

## What other local Mac MCP servers offer

Every broad Apple MCP server reviewed (iMCP, MacRelay, AirMCP, Apple Ecosystem MCP, PyApple)
offers Calendar, Reminders, and Contacts; most add Location and Maps, many Shortcuts, Mail,
Music, Photos, and system settings. iMCP (Swift, menu bar app, the closest to Latchkey) uses
EventKit, the Contacts framework, Core Location, and MapKit. MacRelay's Calendar tools are a
good checklist: list calendars, search, create, reschedule, cancel, update, find available times.
None of them keeps a lasting log of tool calls except AirMCP (a keyed, chained log).

## How each is reached on macOS

| Area | Options | Chosen |
|---|---|---|
| Calendar | EventKit; AppleScript to Calendar (slow, opens the app, odd with repeats); Calendar's cache database (undocumented) | EventKit |
| Reminders | EventKit; AppleScript to Reminders (slow); Reminders' database (undocumented, has flags and tags) | EventKit; since 2026-11-05 also the database (read-only) and Reminders' window for flags, tags, subtasks, and sections (below) |
| Contacts | Contacts framework; AppleScript to Contacts | Contacts framework (already used for Messages) |
| Location | Core Location (Wi-Fi based on a Mac) | Core Location |
| Places, directions, geocoding | MapKit (`MKLocalSearch`, `MKDirections`, `MKGeocodingRequest`, `MKReverseGeocodingRequest`); `CLGeocoder` (deprecated in macOS 26) | MapKit |
| Weather | WeatherKit needs the paid Apple Developer Program; free web services (MET Norway, Open-Meteo, US NWS) | Left out (Toni, 2026-10-26: only what macOS offers) |

Pros of the native frameworks: documented, fast, nothing opens on screen, work while the Mac is
locked or the lid is closed (unlike Computer control), one permission prompt each. Cons: EventKit
can't add attendees or answer invitations (Apple's `EKParticipant` documentation: "you can't add
participants to an event nor change participant information"); it has no flags, tags, subtasks,
or sections for reminders; reading the Contacts note field needs an entitlement Apple grants on
request, so notes are not read.

## Checked on this Mac (2026-10-26, macOS 26, unsigned test program, no entitlements)

- `MKLocalSearch` for "coffee near Walnut Creek, CA" returned places; `MKDirections` returned a
  5.8 km, 10-minute drive. No API key, no Maps entitlement, no developer account.
- `MKGeocodingRequest` and `MKReverseGeocodingRequest` (new in macOS 26) work; addresses come
  as `MKAddress.fullAddress` and `shortAddress`.
- Public transport: `MKDirections.calculateETA()` with `.transit` returned a travel time; full
  transit routes (`calculate()`) are not offered on the Mac, so transit gives the time only.
- `EKEventStore.authorizationStatus` and `CLLocationManager` answer without prompting.

## Permissions

- Calendar and Reminders: `requestFullAccessToEvents` / `requestFullAccessToReminders` (macOS
  14+), Info.plist `NSCalendarsFullAccessUsageDescription`,
  `NSRemindersFullAccessUsageDescription`; hardened runtime entitlement
  `com.apple.security.personal-information.calendars` covers both. "Add only" access
  (`writeOnly`) can't read, so it counts as missing.
- Contacts: already asked for (spec 002); entitlement already present.
- Location: `CLLocationManager.requestWhenInUseAuthorization`, Info.plist
  `NSLocationUsageDescription` and `NSLocationWhenInUseUsageDescription`, entitlement
  `com.apple.security.personal-information.location`. Location Services can be off for the
  whole Mac; then nothing can be measured and the tool says so.
- A prompt raised by a request from the phone would wait on an unattended Mac (spec 002 FR-140),
  so all four are asked for in the setup window only.

## Low-level choices (Claude, recorded per CLAUDE.md)

- **Event ids.** EventKit's `eventIdentifier` is shared by all occurrences of a repeating event.
  Options: (a) the identifier alone, (b) identifier plus the occurrence's start, (c) our own
  table. Chosen (b), written `<identifier>@<start as Unix seconds>`: it names one occurrence
  without storing anything (Constitution VI); a lookup fetches the events of that minute and
  matches the identifier. A plain identifier (no `@`) means the first occurrence.
- **Free time.** Options: count every event; count only busy ones; let Claude pass a filter.
  Chosen: an event counts as busy unless it is all-day, marked free, cancelled, or an invitation
  the Owner declined. Free times are clipped to day hours, default 08:00–20:00, which Claude can
  change (`hours`), so nights don't show as free time.
- **Dates in and out.** Accepted: `YYYY-MM-DD` (all-day or the start of that day),
  `YYYY-MM-DDTHH:MM[:SS]` (Mac's time zone), and either with `Z` or `±HH:MM`. Out: local times
  as `2026-10-27 15:00` with the weekday, and one line naming the time zone and its offset. ISO
  with offsets everywhere was the alternative: precise, but harder to read on a phone.
- **Field updates.** A field given in an update replaces that field; a list (phone numbers,
  emails, addresses, alarms) is replaced as a whole. Alternatives (add/remove operations per
  item) double the schema; Claude reads the card first and sends the full list.
- **Reminder lists.** Creating and deleting a list are offered. Deleting one deletes every
  reminder in it at once, with no way back, so Toni decided (2026-10-28) that the call must
  carry the number of reminders the list holds, and a wrong number is refused with the actual
  one (spec FR-713). Low-level choices (Claude):
  - Shape: an action `delete_list` on `reminders_change` with `list` and `reminder_count`,
    like `create_list`; a separate tool would break the find/change pattern.
  - What counts: open and completed reminders together (options: open only, which the list
    overview already shows; or all). Chosen all, because completed ones are deleted too and a
    count of open ones would let a list of old completed reminders vanish unseen. Reading one
    list (`reminders_find` with `list`) now says "holds N reminders (x open, y completed)", so
    Claude learns the number by looking; the overview without a list keeps open counts only, so
    it doesn't fetch every completed reminder on the Mac.
  - Read-only lists (`allowsContentModifications` false) are refused before counting; anything
    else EventKit refuses (the account's last list, for instance) comes back as its message.
  - The count is read just before the delete, in the same call; nothing is stored between calls
    (Constitution VI).
- **Contact groups.** Listed, shown on a card, and changed: create, rename, delete, add and
  remove cards (Toni, 2026-10-28; spec FR-723). Low-level choices (Claude):
  - Shape: five actions on `contacts_change` (`create_group`, `rename_group`, `delete_group`,
    `add_to_group`, `remove_from_group`) with `group` (name or id, as `contacts_find` takes),
    `name` (the new name), and `id` or `ids` (cards). One action per operation matches the
    reminders and calendar actions; one `group_members` list replacing the whole membership was
    the alternative, but it needs the full member list read first and one stale read drops
    people.
  - Several cards per call (`ids`) so "add these five people" is one call; each card is looked
    up first, so an unknown id changes nothing.
  - Deleting a group asks for no count, unlike a reminder list: no card is deleted, only the
    grouping, and the answer says how many cards stay.
  - Two groups with the same name (any letter case) are refused on create and rename, since
    groups are named by name in every other call.
  - New groups go to the default account (`toContainerWithIdentifier: nil`). A card from
    another account (Exchange, Google) can't join an iCloud group; Contacts refuses and the
    tool passes its message on. Some accounts (Exchange) have no groups at all.
- **Backends behind protocols.** Tests must never touch the Owner's real calendars or contacts
  (`.claude/rules/macos.md`), so the tools talk to small protocols (`EventsBackend`,
  `ContactsBackend`, `PlacesBackend`) with an EventKit/Contacts/MapKit implementation and an
  in-memory one for tests. The real implementations are checked live through the relay with a
  test event, reminder, and contact that are deleted afterwards.
- **Location fix.** One `requestLocation()` with a 10 s limit; a fix up to 5 minutes old is
  reused, so repeated questions don't wait. The address comes from reverse geocoding (network).
- **Search sizes.** Events: up to 200 per answer (default 50), ranges up to 4 years (EventKit's
  limit for one query). Contacts: up to 100 (default 20). Places: up to 25 (default 10).

## Sources

- Apple: [EventKit](https://developer.apple.com/documentation/eventkit),
  [EKParticipant](https://developer.apple.com/documentation/eventkit/ekparticipant),
  [Contacts](https://developer.apple.com/documentation/contacts),
  [Core Location](https://developer.apple.com/documentation/corelocation),
  [MKLocalSearch](https://developer.apple.com/documentation/mapkit/mklocalsearch),
  [WeatherKit](https://developer.apple.com/weatherkit/)
- Servers: [iMCP](https://github.com/mattt/iMCP), [MacRelay](https://github.com/drbarq/macrelay),
  [AirMCP](https://github.com/heznpc/airmcp),
  [Apple Ecosystem MCP](https://glama.ai/mcp/servers/abhinavag-svg/apple-ecosystem-mcp)
- Weather terms checked and not used: [MET Norway](https://api.met.no/doc/TermsOfService),
  [Open-Meteo](https://open-meteo.com/en/terms)

Live check 2026-10-29 (app 0.8.39): a group made through Contacts got a new id within seconds,
as new cards do (iCloud takes them over). A group id that's gone stale is answered with "give
its name instead"; names keep working. The first check's delete message counted a member that
had just been removed (the count was read while the change was still syncing); the second
check counted 0 correctly.

## Ids that change (2026-10-29, spec FR-724 to FR-727; low-level choices by Claude)

Seen live: a card (2026-10-26) and a group (2026-10-29) created through Latchkey got a new id
within seconds, so the id the create answered went stale; and deleting a new group by its first
id deleted one copy while iCloud's copy survived. The Contacts framework gives a card or group
no creation date and no link between the two ids, so Latchkey has to recognise its own.

- **What is remembered.** Options: (a) nothing, answer "search again" (before); (b) a table on
  disk; (c) memory for the app's run. Chosen (c), `ContactsMemory`: the problem lasts seconds to
  minutes, and nothing about the Owner's contacts is written to disk (Constitution VI). Kept per
  card: every id it had, the fingerprint of each version Latchkey wrote, the ids of cards that
  looked the same just before each write, when it was made; per group: ids, every name Latchkey
  gave it, groups that had that name before, fingerprints of the cards Latchkey put in it. At
  most 200 of each (oldest dropped).
- **How a card is recognised.** Options: names only; names plus first email or phone; the whole
  content. Chosen the whole content as a fingerprint: names, nickname, company, job title,
  department, every phone (digits only), email, postal address, web address, date, related name
  (all case- and accent-folded, sorted, labels left out), birthday, and whether it has a
  picture. Labels and phone formatting are left out because iCloud may rewrite them; anything
  else differing (someone added an address) means it isn't Latchkey's copy. Names only would
  take the Owner's other Sarah Jones.
- **How a group is recognised.** By a name Latchkey gave it: names are already unique (create
  and rename refuse a name in use), so at create time no other group has it.
- **Why the Owner's own items can't be deleted.** A card or group is only ever matched to a
  record of something Latchkey created in this run. Cards that already had the same fingerprint
  just before Latchkey created or changed its card (one more full read of Contacts per create,
  and per update of Latchkey's own card), and groups that had the name, are never matched, even
  when identical. Nothing is matched when two live records could share a card (Claude made two
  identical test cards) or when more than one candidate fits. A copy is deleted only within 10
  minutes of the create, a card copy only with exactly the content Latchkey wrote (so nothing
  the Owner typed into it can be lost), a group copy only when every card in it is one Latchkey
  put in the group (and deleting a group never deletes cards). What remains possible: the Owner
  makes, by hand, an exact twin of Latchkey's new card, or an empty same-named group, within
  those 10 minutes, and Claude deletes Latchkey's one; the twin then goes too. Nothing the Owner
  wrote is lost in that case, since the twin holds only what Latchkey wrote.
- **When to look for a copy.** Options: once right after the delete; also a moment later; also
  at later calls. Chosen all three: right after the delete; when nothing was found and the
  create was under 2 minutes ago, once more 2 seconds later (inside the 15 s deadline); and at
  the start of each later `contacts_change` within the 10 minutes. Not at `contacts_find`,
  which is read-only. A copy that appears later than that, with no further change, stays.
- **What the answer says.** "Sarah's id changed to … (iCloud took the card over); use that one.",
  "Also deleted iCloud's copy of the group, which had appeared with a new id.", and for a
  same-named group with other cards, that it was left alone and its id.
- **Calendar and Reminders.** Checked for the same pattern: EventKit's `eventIdentifier` and
  `calendarItemIdentifier` stayed the same in every live check (an event created, moved, and
  deleted, and a reminder created, completed, and deleted, 2026-10-26; a reminder list created
  and deleted, 2026-10-29).
  Apple documents that an event's identifier may change when it moves to another calendar; the
  update answers with the event as saved, so Claude gets the new id. Not changed.

## Flags, tags, subtasks, and sections (2026-11-05, spec FR-714 to FR-719; choices by Claude)

Toni asked to "add everything missing". Reminders' flags, tags (hashtags), subtasks, and sections
were not offered at all, and nobody had checked whether an update loses them. Tried on Toni's
Mac (macOS 27.0.1) with throwaway lists named "Latchkey check 1105 rem", removed afterwards.

What each route can do:

| Route | Reads | Writes | Locked Mac |
|---|---|---|---|
| EventKit (`EKReminder`) | none of the four | none (no properties for them; Apple's EKReminder documentation lists title, dates, priority, completion only) | works |
| Reminders' AppleScript (`sdef /System/Applications/Reminders.app`, macOS 27) | `flagged`; `container` can be a reminder | `flagged` on top-level reminders only; `make new reminder at <reminder>` and `move <reminder> to <reminder>` fail ("AppleEvent handler failed"), and the failed make left the reminder in the default list; a subtask can't be addressed at all (`reminder id` of a subtask: -1728), so it can't be flagged | works; needs a new Automation permission for Latchkey |
| Reminders' database, read-only (`~/Library/Group Containers/group.com.apple.reminders/Container_v1/Stores/Data-*.sqlite`, Core Data) | all: `ZREMCDREMINDER.ZFLAGGED`, `ZPARENTREMINDER`; tags are `ZREMCDOBJECT` rows of entity `REMCDHashtag` (owner `ZREMINDER3`, name `ZNAME1`, label `ZREMCDHASHTAGLABEL`); images and URL attachments are `REMCDImageAttachment` / `REMCDURLAttachment` rows; sections are `ZREMCDBASESECTION` with the list's `ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA` JSON (`memberID`, `groupID`) | never (rule: no writing another app's database; iCloud sync owns it) | works (Full Disk Access, which Latchkey has) |
| Reminders' window through Accessibility, in the background | (what's shown) | each reminder row has its own actions `Indent`, `Outdent`, `Move Up`, `Move Down`: `Indent` made a reminder a subtask with Mail in front, Reminders stayed behind; typing "#name" into a row's title field (set `AXSelectedText`, then `AXConfirm`) made a real tag, also in the background. Menus (Edit → Flag, File → Move to Section) are disabled while Reminders isn't in front, like Notes' | no window rows at all: the window list holds no reminders outline (and a recursive look at it hung for minutes until a 2 s messaging timeout was set) |
| Reminders' private framework (ReminderKit) | all | all | — rejected: private framework (Constitution IV), and its store needs Apple's own entitlements |

Checked live, every result read back from the database:

- **Ids.** EventKit's `calendarItemIdentifier`, the database's `ZCKIDENTIFIER`, and the
  AppleScript id (`x-apple-reminder://<id>`) are the same UUID, so the database is joined to
  EventKit's reminders by id.
- **EventKit keeps them.** Changing a parent's title (dropping the "#tag" text from it), notes,
  and due date, and a subtask's title and notes, kept the flag, the tag, and the subtask link.
  EventKit's `url` is `ZICSURL` on the reminder, not an attachment row, so URL attachments and
  images made in the Reminders app are never touched by an EventKit save.
- **EventKit and a reminder with subtasks moving lists.** Moving the parent alone is refused
  (ReminderKit error -3002, "Subtask has different list from its parent reminder"; nothing
  changes). Moving parent and subtask in one commit succeeds but drops the link: both arrive as
  separate reminders. So Latchkey moves them together and puts each subtask back under the
  parent in the window (unlocked only); on a locked Mac it refuses before changing anything.
- **Tags.** A title set through EventKit or AppleScript with "#name" makes no tag. Typed into
  the window's title field it does, and the "#name" text stays in the title; Latchkey then sets
  the title back through EventKit and the tag stays.
- **Not found: removing a tag** (see "Still open" below).

Choices:

- **Reading.** Options: (a) EventKit only, saying flags and tags are unknown; (b) the database,
  read-only, per call; (c) the window. Chosen (b): complete, fast, works locked and with the lid
  closed, and doesn't touch Reminders. Column names that differ between macOS versions are
  looked up in each file; a missing column only leaves that detail out. Without Full Disk Access
  the answers say flags, tags, and subtasks are unknown (never "none").
- **Writing.** Options, least to most intrusive: (a) AppleScript; (b) the window's row actions
  and title field in the background; (c) menus with Reminders brought forward for a moment.
  AppleScript was rejected: it can't make subtasks, can't reach subtasks to flag them, and would
  add an Automation prompt to setup. Chosen (b) for subtasks and tags, (c) for flags and sections,
  where no background action exists (the same brief activation Notes' ticking uses, Toni's
  2026-11-04 approval of that pattern). The reminder is selected by opening Reminders' own link
  `x-apple-reminderkit://REMCDReminder/<id>` without activating Reminders.
- **Putting a reminder under a parent.** `Indent` puts a row under the nearest reminder above
  it, so the row first moves (`Move Up` / `Move Down`, one step at a time, at most twice the
  rows) until the parent, or the parent's last subtask, is right above it
  (`ReminderRowPlan`). Rows are matched by title; the result is always checked in the
  database, and a wrong parent is reported, not hidden.
- **Every window change is checked in the database** (up to 5 s) and the answer says plainly
  what was done before a step that didn't take.
- **Locked Mac.** Window changes are refused at once, before any change, with the reason
  ("works once the Mac is unlocked"); reading and EventKit changes keep working.
- **Tags in arguments.** `tags` is the whole set after the change (Claude reads them first), as
  a JSON list or a comma-separated string, "#" optional, spaces become "-" (Reminders' tags
  have no spaces).
