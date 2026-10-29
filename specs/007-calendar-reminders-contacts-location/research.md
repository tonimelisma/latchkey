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
| Reminders | EventKit; AppleScript to Reminders (slow); Reminders' database (undocumented, has flags and tags) | EventKit |
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
