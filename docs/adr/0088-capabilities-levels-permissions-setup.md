# 0088. Capabilities, levels, permissions, setup (FR-741, FR-742)

- Status: accepted
- Date: 2026-10-26
- Alias: plan 007 D5 (`specs/007-calendar-reminders-contacts-location/plan.md`, "D5. Capabilities, levels, permissions, setup (FR-741, FR-742)")

## Context and problem

Decision D5 of spec 007's plan (Calendar, Reminders, Contacts, Location and Maps); requirements in
[requirements/calendar-reminders-contacts-location.md](../requirements/calendar-reminders-contacts-location.md). Requirement IDs it cites: FR-741, FR-742, FR-745, SC-704.
The design it belongs to: [design/calendar-reminders-contacts-location.md](../design/calendar-reminders-contacts-location.md).

## Decision


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

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
