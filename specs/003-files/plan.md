# Plan 003: Files — HOW

Derived from `spec.md`; evidence and low-level choices in `research.md`.

## D1. Tools

Claude sees consolidated tools (Toni, 2026-10-23: 15 tools in all, from 45): the table below. The operations listed after it are their internals, each reached by an `action` or by which arguments are given.

| Tool | Level | readOnly | destructive | Operations behind it |
|---|---|---|---|---|
| `files_find` (query?, path?, hidden?, limit) | Read only | yes | no | with query: search; a folder: list; a file: info |
| `files_read` (path, offset?) | Read only | yes | no | read |
| `files_change` (action: write, append, edit, create_folder, move, copy, trash; …) | Read & write | no | yes | write, edit, create folder, move, copy, trash |

Operations:

| Tool | Level | readOnly | destructive | Serves |
|---|---|---|---|---|
| `files_search` (query, folder?, limit) | Read only | yes | no | FR-201 |
| `files_list` (path, hidden?) | Read only | yes | no | FR-201 |
| `files_info` (path) | Read only | yes | no | FR-201 |
| `files_read` (path, offset?) | Read only | yes | no | FR-201, FR-206, FR-207 |
| `files_write` (path, text, overwrite?, append?) | Read & write | no | yes | FR-202, FR-204 |
| `files_edit` (path, find, replace) | Read & write | no | yes | FR-202 |
| `files_create_folder` (path) | Read & write | no | no | FR-202 |
| `files_move` (from, to) | Read & write | no | no | FR-202, FR-204 |
| `files_copy` (from, to) | Read & write | no | no | FR-202, FR-204 |
| `files_trash` (path) | Read & write | no | yes | FR-202, FR-203 |

Deadlines: search 30 s, reads 30 s (iCloud downloads), changes 10 s.

## D2. Reading

Plain text by encoding detection; PDFs with PDFKit; .docx/.doc/.rtf/.rtfd/.odt/.html/.webarchive
with `NSAttributedString`; images with the shared image preparation (spec 002). Other files:
details only, with "not readable as text". At most 100,000 characters per answer, `offset` to
continue (FR-207). Each answer starts by saying the content is the file's (FR-206).
iCloud placeholders are downloaded with `FileManager.startDownloadingUbiquitousItem` and waited
for up to 20 s.

## D3. Changing

FileManager for writes (atomic for new and replaced files), folders, moves, copies, and
`trashItem` (FR-203). Moves and copies refuse an existing destination; writes refuse an
existing file without `overwrite` (FR-204). Each change returns an `activity`, which posts the
notification and goes in the trace (FR-208).

## D4. Search

`mdfind` (Spotlight) as a process, name or content, optional folder, newest first; with a 20 s
deadline. `mdfind` has no `--`, so a query starting with `-` gets a leading space, which Spotlight
ignores, and is never read as an option such as `-live` (security scan, 2026-10-24). The answer notes that Spotlight skips hidden and excluded folders.

## D5. Levels and setup

New capability `files` in the registry, levels Off / Read only / Read & write, default Read &
write (FR-209). Needs Full Disk Access, the step setup already has (spec 002).

## Testing (Constitution VII)

Tests against a temporary folder: read text, PDF (made with PDFKit), RTF, image; offset paging;
search through a fake runner for `mdfind` and one real `mdfind` call on a temporary file;
write/overwrite rules; edit exactly-once; move/copy refusals; trash puts the file in the Trash
(checked, then removed from the Trash by the test); tool list per level.

## Constitution check

| Article | Status |
|---|---|
| I. Outbound only | Pass: no change |
| II. Fail fast | Pass: deadlines on every tool; iCloud waits capped at 20 s |
| III. Disabled means nonexistent | Pass: tools per level |
| IV. Good macOS citizen | Pass: Full Disk Access granted by the Owner; Trash, never erase |
| V. Self-hostable | Pass: relay unchanged |
| VI. Store the minimum | Pass: no index or copies kept; Spotlight is the system's |
| VII. Test-first | Planned above |
| VIII. Simplicity | Pass: Foundation, PDFKit, mdfind; no new dependencies |
| IX. Open source | Pass |
