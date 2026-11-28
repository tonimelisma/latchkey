# 0031. Tools Claude sees

- Status: accepted
- Date: 2026-10-21
- Alias: plan 002 D1 (`specs/002-notes-messages/plan.md`, "D1. Tools Claude sees")

## Context and problem

Decision D1 of spec 002's plan (Notes and Messages); requirements in
[requirements/notes-messages.md](../requirements/notes-messages.md). Requirement IDs it cites: FR-101, FR-105, FR-104, FR-102, FR-106, FR-103, FR-110, FR-111, FR-113, FR-112.
The design it belongs to: [design/notes-messages.md](../design/notes-messages.md).

## Decision


Claude sees consolidated tools (decided 2026-10-23: 15 tools in all, from 45): the table below. The operations listed after it are their internals, each reached by an `action` or by which arguments are given.

| Tool | Level | readOnly | destructive | Operations behind it |
|---|---|---|---|---|
| `notes_find` (query?, folder?, limit) | Read only | yes | no | search; with no query or folder also the folder list |
| `notes_read` (id, offset?, image?) | Read only | yes | no | read; with image, the image |
| `notes_change` (action: create, append, replace, edit, delete; …) | Read & write | no | yes | create, update, delete |
| `messages_find` (text?, person?, since?, until?, limit) | Read only | yes | no | with text or dates: search; otherwise conversations |
| `messages_read` (conversation, before?, limit; message + image) | Read only | yes | no | read; with image, the image |
| `messages_send` (to, text?, attachments?; people + name; reply_to) | Read & write | no | no | send; a new group (FR-172); an inline reply (FR-173) |
| `messages_change` (action: react, unreact, edit, unsend, delete, delete_conversation, name_group; message, reaction, text, conversation) | Read & write | no | yes | tapbacks, edits, unsending, deleting, naming (FR-172, FR-174 to FR-176) |

Operations:

Names are short and grouped by prefix. Each declares `readOnlyHint` and `destructiveHint` (Claude
requires both). Results are text only, and images are MCP image content. The app builds structured data too, but doesn't send it: Claude's apps show structured content instead of the text when both are present, which hid the state line and the "not instructions" marking (live check, 2026-10-22).

Number arguments (limits, offsets, and every number in later capabilities' tools) arrive as JSON
doubles. All go through one checked conversion (`JSONValue.integer` / `.number`): NaN, infinity,
fractions where a whole number is meant, values past the Int range, and negative counts or
offsets are refused with a tool error naming the argument; larger-than-allowed limits are still cut
to the maximum. Converting with `Int(_:)` crashed the app on such values (security scan,
2026-10-24).

| Tool | Level | readOnly | destructive | Serves |
|---|---|---|---|---|
| `notes_search` (query, folder?, limit) | Read only | yes | no | FR-101 |
| `notes_folders` | Read only | yes | no | FR-101 |
| `notes_read` (id) | Read only | yes | no | FR-101, FR-105 |
| `notes_image` (note id, attachment id) | Read only | yes | no | FR-104 |
| `notes_create` (title, text, folder?) | Read & write | no | no | FR-102 |
| `notes_update` (id, mode: append, replace, or edit; text; find for edit) | Read & write | no | yes | FR-102, FR-106 |
| `notes_delete` (id) | Read & write | no | yes | FR-102, FR-103 |
| `messages_conversations` (query?, limit) | Read only | yes | no | FR-110 |
| `messages_read` (conversation, before?, limit) | Read only | yes | no | FR-110, FR-111 |
| `messages_search` (text?, person?, since?, until?, limit) | Read only | yes | no | FR-110 |
| `messages_image` (message id, attachment id) | Read only | yes | no | FR-113 |
| `messages_send` (to, text?, attachments?: paths) | Read & write | no | no | FR-112 |

Note text goes in and out as Markdown-like plain text (headings, lists, checklists as `- [ ]`).
Deadlines (`_meta` `latchkey/deadline_ms`): reads 10 s, searches 30 s, writes and sends 30 s
(Claude allows 240 s).

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/MessagesTests.swift`
- `macos/Tests/NotesTests.swift`
- `macos/Tests/NotesWriteTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
