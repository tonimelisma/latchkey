# 0032. Reading: the databases, read-only

- Status: accepted
- Date: 2026-10-21
- Alias: plan 002 D2 (`specs/002-notes-messages/plan.md`, "D2. Reading: the databases, read-only")

## Context and problem

Decision D2 of spec 002's plan (Notes and Messages); requirements in
[requirements/notes-messages.md](../requirements/notes-messages.md). Requirement IDs it cites: FR-101, FR-110, FR-150.
The design it belongs to: [design/notes-messages.md](../design/notes-messages.md).

## Decision


Serves FR-101, FR-110, FR-150; research "Apple Notes", "Messages".
- Notes: `NoteStore.sqlite` in the Notes group container, opened read-only with SQLite's
  `immutable=0, mode=ro` and a busy timeout. Note bodies are gzip-compressed protobuf; a small
  Swift decoder extracts text, paragraph styles (headings, lists, checklists with done state) and
  attachment references. The schema is checked at startup; on an unknown schema, reads fall back
  to AppleScript (slower, no checklist state).
- Messages: `~/Library/Messages/chat.db`, read-only. Text comes from `text` or, on recent macOS,
  from decoding the `attributedBody` typedstream. Apple-epoch timestamps in seconds or nanoseconds.
- Search: SQLite queries with `LIKE` over decoded text, cached per note or message in memory and
  refreshed by file modification time (no copy of the data is written anywhere).
- Both need Full Disk Access (D5).

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/MessagesTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
