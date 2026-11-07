# Spec 007: Calendar, Reminders, Contacts, Location and Maps — WHAT and WHY

**Withdrawn 2026-11-07 (Toni: Latchkey never disturbs the user while the Mac is unlocked, Constitution IV):** the window steps of FR-714 to FR-719: setting flags, tags, subtasks, and sections, and moving a reminder with subtasks (or a subtask) to another list, which needed the Reminders app's window. They are still read and shown; `reminders_change` refuses them and changes nothing.

Status: Approved to build without a review stop (Toni, 2026-10-26); Toni reviews at the end.
Scope: the Owner's calendars, reminders, and contacts on the Mac, where the Mac is, and finding
places and directions. Only what macOS itself offers, with no developer account (Toni,
2026-10-26). This reverses the 2026-10-22 roadmap decision for Calendar, Reminders, and Contacts.
Out of scope: weather (Apple's weather service needs a paid developer account; Toni, 2026-10-26:
leave it out), Mail, Shortcuts, Photos. Inviting people and answering invitations were out of
scope until 2026-11-05 (Toni: "add everything missing"); FR-705 to FR-708 bring them in.

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
3. Given Read & write, when I ask Claude to delete a reminder list, then it deletes the list
   only after it has looked at how many reminders the list holds (Toni, 2026-10-28).
4. Given Read & write and the Mac unlocked, when I ask Claude to flag a reminder, tag it, add
   subtasks under it, or move it into a section, then it does; changing any reminder never loses
   its subtasks, tags, flag, links, or images (Toni, 2026-11-05: "add everything missing").

### US3 (P1): My contacts
1. Given Contacts is Read only or more, when I ask "what's Sarah's address?", then Claude finds
   the card and reads it.
2. Given Read & write, when I ask Claude to add a person, change a number, or delete a card,
   then it does.
3. Given Read & write, when I ask Claude to make a group, rename or delete one, or put people
   in a group or take them out, then it does (Toni, 2026-10-28).

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
- **FR-704** (changed 2026-11-05) When Claude asks to change an event in a calendar the Owner
  can't change (subscribed calendars, holidays, birthdays, others' calendars shared read-only),
  the tool shall say that the calendar is read-only, instead of acting. (Until 2026-11-05 it also
  refused invitations and others' events, saying macOS doesn't allow them; FR-705 to FR-708
  replace that.)
- **FR-705** While Read & write, when Claude asks to accept, tentatively accept ("maybe"), or
  decline an invitation from someone else, optionally with a note to the organizer, for one
  occurrence or it and all later ones, the system shall record the Owner's answer in the
  calendar's account, which tells the organizer, read the answer back, and say what was answered.
  When the account doesn't take answers for that event (a calendar shared by someone else, a
  cancelled event), the system shall say so instead.
- **FR-706** While Read & write, when Claude asks to invite people (by email address) to a new
  or existing event, or to take invited people off it, the system shall add or remove them so
  the calendar's account sends the invitations or cancellations, read the attendees back, and
  name who was invited or uninvited. The system shall refuse, with the reason, an address that
  is the calendar's own (the Owner), a calendar whose account doesn't send invitations (On My
  Mac), an invitation whose organizer doesn't let guests invite others, and uninviting someone
  who isn't invited.
- **FR-707** While Read & write, when Claude asks to change or delete an event someone else
  organized, the system shall do it in the Owner's calendar and say that only the Owner's copy
  changed (the organizer and other guests keep theirs) unless the account lets the Owner act as
  organizer; deleting such an event shall point to declining as the way to tell the organizer.
- **FR-708** When reading an invitation (FR-701), the system shall show the Owner's current
  answer and whether it can be answered on this Mac. These shall work while the Mac is locked
  and with the lid closed; when this macOS lacks the calendar calls they need, the system shall
  say so and that the Calendar app (through Computer control) can still do it.

### Reminders
- **FR-711** While Reminders is Read only or Read & write, Claude shall be able to list the
  reminder lists with their open counts, list and search reminders (open ones, or completed ones
  in a time range), and read one in full: title, notes, list, due date, priority, completed and
  when, link, alarms, how it repeats.
- **FR-712** While Read & write, Claude shall be able to create, change, complete, mark not
  completed, and delete reminders, and create a reminder list.
- **FR-713** While Read & write, Claude shall be able to delete a reminder list, with all the
  reminders in it, by giving the list and the number of reminders it holds (open and
  completed). When the number given isn't the list's actual number, the tool shall delete
  nothing and say the actual number, so Claude can't delete a list it hasn't looked at (Toni,
  2026-10-28). Reading one list (FR-711) shall say how many reminders it holds, open and
  completed.
- **FR-714** While Reminders is Read only or more, Claude shall see each reminder's flag, tags,
  section, images, and attached links, and its subtasks under it (or, for a subtask, its
  parent), and shall be able to search by tag; reading one list shall name its sections. When
  Latchkey can't read them, the answer shall say they are unknown, never that there are none.
- **FR-715** While Read & write, Claude shall be able to flag and unflag a reminder.
- **FR-716** While Read & write, Claude shall be able to add tags to a reminder, when creating
  it or later. When Claude asks to remove a tag and no way to do it exists, the tool shall
  change nothing and say so.
- **FR-717** While Read & write, Claude shall be able to create a subtask under a reminder,
  make an existing reminder a subtask of another, and make a subtask a reminder of its own
  again; subtasks are listed, completed, changed, and deleted like any reminder. A subtask
  can't have subtasks (Reminders has one level); such a request shall be refused with that
  reason.
- **FR-718** While Read & write, Claude shall be able to move a reminder into one of its list's
  sections, or out of its section.
- **FR-719** No change Claude makes shall lose a reminder's subtasks, tags, flag, links, or
  images. When a reminder with subtasks moves to another list, its subtasks shall move with it
  and stay its subtasks. When a change of FR-715 to FR-718 can't be made in the Mac's current
  state (locked), the tool shall change nothing, answer at once, and say which state it needs;
  when one step of a change doesn't take, the answer shall say what was done and what wasn't.

### Contacts
- **FR-721** While Contacts is Read only or Read & write, Claude shall be able to search
  contacts by name, nickname, company, email address, or phone number, list the groups, read a
  card in full (names, company, job title, phone numbers, email addresses, postal addresses,
  birthday and other dates, web addresses, related names, groups), and see its photo.
- **FR-722** While Read & write, Claude shall be able to create a card, change its fields, and
  delete it.
- **FR-723** While Read & write, Claude shall be able to create a contact group, rename it,
  delete it (its cards stay in Contacts), and add cards to it or remove them from it (Toni,
  2026-10-28).
- **FR-724** When Claude gives the id of a card that Latchkey created while the app has been
  running, and no card has that id any more (iCloud gave it a new one), the tool shall find the
  card again by its content, act on it, and say its new id. It shall not guess when more than
  one card could be meant, and never take a card that already looked the same before Latchkey
  created it (live checks 2026-10-26 and 2026-10-29).
- **FR-725** When Claude gives the id of a group that Latchkey created while the app has been
  running, and no group has that id any more, the tool shall find the group again by its name,
  act on it, and say its new id.
- **FR-726** When Claude deletes a card or group that Latchkey created while the app has been
  running, within 10 minutes of creating it, the tool shall also delete any copy of it that
  appeared under another id (iCloud's): for a card, one with exactly the content Latchkey wrote
  that didn't exist before Latchkey created or changed it; for a group, one with a name Latchkey
  gave it that no other group had, holding only cards Latchkey put in the group. A same-named
  group holding other cards shall be left alone and named in the answer. The Owner's own cards
  and groups, including ones that look the same, shall never be deleted this way (live check
  2026-10-29: deleting a new group left iCloud's copy behind).
- **FR-727** When such a copy appears only after the delete has answered, the next change Claude
  makes in Contacts within that 10 minutes shall delete it the same way and say so.

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
- **FR-743** Every change Claude makes (event, reminder, list, contact, group) shall show a
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
