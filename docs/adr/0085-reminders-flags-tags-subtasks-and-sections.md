# 0085. Reminders' flags, tags, subtasks, and sections (FR-714 to FR-719)

- Status: accepted
- Date: 2026-11-05
- Alias: plan 007 D7 (`specs/007-calendar-reminders-contacts-location/plan.md`, "D7. Reminders' flags, tags, subtasks, and sections (FR-714 to FR-719)")

## Context and problem

Decision D7 of spec 007's plan (Calendar, Reminders, Contacts, Location and Maps); requirements in
[requirements/calendar-reminders-contacts-location.md](../requirements/calendar-reminders-contacts-location.md). Requirement IDs it cites: FR-714, FR-719, FR-715, FR-718.
The design it belongs to: [design/calendar-reminders-contacts-location.md](../design/calendar-reminders-contacts-location.md).

## Decision


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

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
