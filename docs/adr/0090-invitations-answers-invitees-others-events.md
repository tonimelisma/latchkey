# 0090. Invitations: answers, invitees, others' events (FR-705 to FR-708; 2026-11-05)

- Status: accepted
- Date: 2026-11-05
- Alias: plan 007 D7 (`specs/007-calendar-reminders-contacts-location/plan.md`, "D7. Invitations: answers, invitees, others' events (FR-705 to FR-708; 2026-11-05)")

## Context and problem

Decision D7 of spec 007's plan (Calendar, Reminders, Contacts, Location and Maps); requirements in
[requirements/calendar-reminders-contacts-location.md](../requirements/calendar-reminders-contacts-location.md). Requirement IDs it cites: FR-705, FR-708, FR-706, FR-707.
The design it belongs to: [design/calendar-reminders-contacts-location.md](../design/calendar-reminders-contacts-location.md).

## Decision


- Mechanism: the EventKit calls Calendar.app itself uses, on the same `EKEvent` objects and the
  same `save(_:span:commit:)` (`EventKitInvitations`; options and choice in research.md
  "Invitations"). The account (Google, Exchange, iCloud) sends the invitations, cancellations,
  and answers, as when the Owner does it in Calendar. No window, no Apple Events: it works while
  the Mac is locked and with the lid closed, like every other Calendar change.
- `respond` (FR-705): sets the event's `participationStatus` (and `responseComment` for a note),
  saves with the span asked for, then reads the answer back; a different answer after the save
  is an error. Allowed only for an invitation from someone else that the account lets the Owner
  answer (`allowsParticipationStatusModifications`, not cancelled); otherwise the reason.
- `invite` / `uninvite` (FR-706), on create and update: `EKAttendee
  attendeeWithName:emailAddress:` and `addAttendee:`; the first invitee also gets
  `addOrganizerAndSelfAttendeeForNewInvitation`, as in Calendar, so the Owner is the organizer
  (without it the account drops the attendees on save, seen live 2026-11-05). `removeAttendee:`
  takes people off; when only the Owner is left, the Owner's own entries go too, so the event is
  a plain event again. The Owner's addresses (the account's `ownerAddresses`, the calendar's
  self and owner identities) are refused as invitees: macOS drops them silently. Allowed for the
  Owner's own events in a CalDAV, Exchange, or iCloud calendar, and for others' invitations only
  when the organizer lets guests invite (`allowsAttendeesModifications`). After the save the
  attendees are read back; anyone missing or still there is named in an error.
- Others' events (FR-707): changed and deleted like the Owner's; the answer says only the Owner's
  copy changed unless `currentUserMayActAsOrganizer`. Deleting one points to `respond decline`.
- Reading (FR-708): `Your answer: …` and whether `respond` can answer it.
- Each call is looked up before use (`responds(to:)`); when one is missing on a future macOS,
  the answer says so and points to the Calendar app through Computer control
  (`eventKitStillHasTheInvitationCalls` fails first, before a release).
- Tests: the tool routing and messages against the in-memory backend; the real EventKit calls on
  unsaved events (invite, no duplicates, uninvite, the Owner's own address refused). Live, with
  the installed app's Calendar permission (2026-11-05): an event saved and deleted in the
  Exchange calendar with the Owner's own address refused, and, in memory only, invite and
  uninvite in every writable Google and Exchange calendar and an answer on real invitations.
  Sending real invitations and answers to other people isn't tested live: test invitations may
  go only to the Owner's own address, which is never an invitee (screen-state cases
  `calendar.invite_own`, `calendar.invitation_read`).

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
