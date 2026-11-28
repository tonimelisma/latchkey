# 0083. Tools Claude sees

- Status: accepted
- Date: 2026-10-26
- Alias: plan 007 D1 (`specs/007-calendar-reminders-contacts-location/plan.md`, "D1. Tools Claude sees")

## Context and problem

Decision D1 of spec 007's plan (Calendar, Reminders, Contacts, Location and Maps); requirements in
[requirements/calendar-reminders-contacts-location.md](../requirements/calendar-reminders-contacts-location.md). Requirement IDs it cites: FR-701, FR-702, FR-703, FR-707, FR-711, FR-714, FR-712, FR-713, FR-715, FR-719, FR-721, FR-722, FR-723, FR-731, FR-732, FR-734.
The design it belongs to: [design/calendar-reminders-contacts-location.md](../design/calendar-reminders-contacts-location.md).

## Decision


Two tools per capability, in the find/change pattern of the other capabilities (decided
2026-10-23); 8 new tools, 23 in all. Location & Maps has no changes, so its two tools are both
read-only.

| Tool | Level | readOnly | destructive | Serves |
|---|---|---|---|---|
| `calendar_find` (id?, query?, from?, to?, calendar?, free?, minutes?, hours?, limit?) | Read only | yes | no | FR-701, FR-702 |
| `calendar_change` (action: create, update, delete, respond; id, title, start, end, all_day, calendar, location, notes, url, alarms, repeat, repeat_every, repeat_until, repeat_count, span, invite, uninvite, answer, comment) | Read & write | no | yes | FR-703 to FR-707 |
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

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
