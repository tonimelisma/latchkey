# Spec 007: Calendar, Reminders, Contacts, Location and Maps — WHAT and WHY

Status: Approved to build without a review stop (Toni, 2026-10-26); Toni reviews at the end.
Scope: the Owner's calendars, reminders, and contacts on the Mac, where the Mac is, and finding
places and directions. Only what macOS itself offers, with no developer account (Toni,
2026-10-26). This reverses the 2026-10-22 roadmap decision for Calendar, Reminders, and Contacts.
Out of scope: weather (Apple's weather service needs a paid developer account; Toni, 2026-10-26:
leave it out), inviting people to events or answering invitations (macOS doesn't let apps do
it), Mail, Shortcuts, Photos.

## Problem

From a phone, the Owner wants Claude to answer "am I free Thursday afternoon?", add a dentist
appointment, check off a reminder, look up a friend's address, or ask how long the drive home
takes. These live in the Mac's Calendar, Reminders, and Contacts, which sync with iCloud and other
accounts, and in Apple Maps.

## User stories

### US1 (P1): My calendar
1. Given Calendar is Read only or more, when I ask "what's on tomorrow?", then Claude lists the
   events of all my calendars, with times in the Mac's time zone.
2. Given Read only or more, when I ask "when am I free for an hour this week?", then Claude
   lists the free times.
3. Given Read & write, when I ask Claude to add, move, or delete an event, then it does, and a
   notification on the Mac says what changed.

### US2 (P1): My reminders
1. Given Reminders is Read only or more, when I ask "what do I need to do?", then Claude lists
   my open reminders by list and due date.
2. Given Read & write, when I ask Claude to remind me of something, check something off, change
   or delete a reminder, or start a new list, then it does.

### US3 (P1): My contacts
1. Given Contacts is Read only or more, when I ask "what's Sarah's address?", then Claude finds
   the card and reads it.
2. Given Read & write, when I ask Claude to add a person, change a number, or delete a card,
   then it does.

### US4 (P2): Where the Mac is, places, and directions
1. Given Location & Maps is On, when I ask "where is my Mac?", then Claude gives its location
   and address.
2. When I ask for coffee near the office, or how long the drive from home to the airport takes
   by car, on foot, or by public transport, then Claude answers from Apple Maps.

## Requirements

### Calendar
- **FR-701** While Calendar is Read only or Read & write, Claude shall be able to list the
  calendars, list events in a time range (all calendars or chosen ones, repeating events as
  their single occurrences), search events by text, and read one event in full: title, times,
  all-day, calendar, location, notes, link, alarms, how it repeats, attendees and their answers,
  and whether it can be changed.
- **FR-702** While Read only or more, Claude shall be able to find free times of at least a
  given length in a time range, across all calendars, counting only events that make the Owner
  busy.
- **FR-703** While Read & write, Claude shall be able to create an event (title, start and end
  or all-day dates, calendar, location, notes, link, alarms, repetition), change any of these,
  and delete an event. For a repeating event, a change or deletion applies to the one occurrence
  or to it and all later ones, as Claude chooses.
- **FR-704** When Claude asks to invite people, or to change an event in a calendar the Owner
  can't change (subscribed calendars, holidays, others' invitations), the tool shall say that
  macOS doesn't allow it, instead of acting.

### Reminders
- **FR-711** While Reminders is Read only or Read & write, Claude shall be able to list the
  reminder lists with their open counts, list and search reminders (open ones, or completed ones
  in a time range), and read one in full: title, notes, list, due date, priority, completed and
  when, link, alarms, how it repeats.
- **FR-712** While Read & write, Claude shall be able to create, change, complete, mark not
  completed, and delete reminders, and create a reminder list.

### Contacts
- **FR-721** While Contacts is Read only or Read & write, Claude shall be able to search
  contacts by name, nickname, company, email address, or phone number, list the groups, read a
  card in full (names, company, job title, phone numbers, email addresses, postal addresses,
  birthday and other dates, web addresses, related names, groups), and see its photo.
- **FR-722** While Read & write, Claude shall be able to create a card, change its fields, and
  delete it.

### Location and Maps
- **FR-731** While Location & Maps is On, Claude shall be able to get the Mac's current
  location: coordinates, accuracy, when it was measured, and the address.
- **FR-732** While On, Claude shall be able to search Apple Maps for places by name or kind
  near an address, coordinates, or the Mac, with each place's address, phone, web address, and
  distance.
- **FR-733** While On, Claude shall be able to get directions and travel time between two
  places (addresses, coordinates, or the Mac's location) by car or on foot, with the steps, and
  the travel time by public transport, optionally for a departure or arrival time.
- **FR-734** While On, Claude shall be able to turn an address into coordinates and
  coordinates into an address.

### Common
- **FR-741** Calendar, Reminders, and Contacts shall have the levels Off, Read only, Read &
  write; Location & Maps shall have Off and On. All four shall start fully on after the update
  (Toni, 2026-10-26).
- **FR-742** Each capability's macOS permission (Calendars, Reminders, Contacts, Location) shall
  be asked for in the setup window and shown in the Settings window's Permissions tab, never
  when a request arrives. When it is missing, the tools shall say what to turn on.
- **FR-743** Every change Claude makes (event, reminder, list, contact) shall show a
  notification naming it, and appear in the activity log.
- **FR-744** Times shall be read and written in the Mac's time zone unless Claude gives another
  offset, and every answer with times shall name the time zone.
- **FR-745** The Contacts switch shall control only the Contacts tools: names in Messages keep
  working whenever macOS allows Latchkey to read Contacts (Toni, 2026-10-26).
- **FR-746** Text that others wrote (event notes and titles of invitations from others,
  attendee names) shall be marked as content, not instructions, the way messages are (spec 002
  FR-114).

## Success criteria

- **SC-701** From a phone, Claude answers "what's on my calendar tomorrow?" correctly for the
  Owner's real calendars.
- **SC-702** Claude adds, moves, and deletes a test event and a test reminder; the Owner's other
  events and reminders are unchanged.
- **SC-703** With any of the three at Read only, no tool that changes anything appears (test
  suite); with Location & Maps Off, neither location tool appears.
- **SC-704** Without a permission, the tool answers within 2 s with what to turn on.

## Edge cases

- Repeating events, all-day events across several days, events in other time zones.
- Calendars from iCloud, Google, Exchange, and subscriptions, some read-only.
- Two people named Sarah; a phone number written in different formats.
- Location Services turned off for the whole Mac; the Mac without Wi-Fi (no fix).
- Places or directions that Maps can't find; public transport not available in that region.
- Over 10,000 contacts or events in a range (answers come in pages).
