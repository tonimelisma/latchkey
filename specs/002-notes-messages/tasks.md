# Tasks 002: Notes and Messages

From `plan.md`. Built in increments; each ends with tests passing, a disk image, the relay
deployed if it changed, a commit, and a push (Toni, 2026-10-22). `[P]` = parallel-safe.

## Increment 1: foundations

- **T101** Relay: append the Mac's state line to every Mac tool result; offline answers unchanged;
  remove `laptop_status`. Tests first (mcpserver). *FR-065 (spec 001), D7.*
- **T102** Contracts: mcp-surface without `laptop_status`/`battery_status`, with the state line.
- **T103** App: capability levels (Off, Read only, Read & write) for `notes` and `messages`,
  stored in user defaults, starting at Read & write; tools sent per level; remove "System info"
  and `battery_status`. Tests first. *FR-120, FR-121, D9.*
- **T104** App: menu shows the 10 most recent activities (expandable) and a busy dot on the icon
  while a call runs; notifications helper for changes. *FR-130 to FR-132, D8.*
- **T105** App: setup window step for Full Disk Access (detect by opening the databases; button
  opens the System Settings page; notices the change). Info.plist usage strings and the Apple
  Events entitlement. *FR-140, D5.*

## Increment 2: Notes reading

- **T110** [P] Fixture `NoteStore.sqlite` built by a script: folders, notes with compressed
  protobuf bodies (headings, lists, checklists, an image attachment), a locked note.
- **T111** Tests first, then the note body decoder (gzip + protobuf → text with Markdown-like
  styles, checklist state, attachment references). *D2.*
- **T112** Tests first, then the Notes store: schema discovery, folders, search, read, locked
  notes, image lookup. *FR-101, FR-104, FR-105, FR-150.*
- **T113** Tools `notes_search`, `notes_folders`, `notes_read`, `notes_image`. *D1.*

## Increment 3: Notes changes

- **T120** Apple Events runner behind a protocol (fake in tests); Markdown-like text → Notes HTML.
- **T121** Tools `notes_create`, `notes_update` (replace, append), `notes_delete`; notifications.
  *FR-102, FR-103, FR-130.*

## Increment 4: Messages reading

- **T130** [P] Fixture `chat.db`: handles, chats (one-to-one and group), messages with `text` and
  with `attributedBody` only, attachments, nanosecond timestamps.
- **T131** Tests first, then the `attributedBody` decoder and the Messages store (conversations,
  read, search). *FR-110, D2.*
- **T132** Contacts lookup (numbers and emails → names; names → handles; ambiguity). *FR-111, D4.*
- **T133** Others' text marked in results; injection test. *FR-114, SC-104, D6.*
- **T134** Tools `messages_conversations`, `messages_read`, `messages_search`, `messages_image`.

## Increment 5: Messages sending

- **T140** Tool `messages_send` (to person, number, email, or conversation; text; attachments);
  confirmation from `chat.db`; notification. *FR-112, FR-130, D3.*

## Each increment ends with

- Relay and Mac tests and lint pass; `make -C macos dmg`; `deploy/deploy-vps.sh` if the relay
  changed; status, decisions, and tasks updated; commit; push the branch and fast-forward `main`.
