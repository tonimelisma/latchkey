# 0121. Files on Linux (FR-1040 to FR-1044)

- Status: accepted
- Date: 2026-10-31
- Alias: plan 010 D10 (`specs/010-multi-host/plan.md`, "D10. Files on Linux (FR-1040 to FR-1044)")

## Context and problem

Decision D10 of spec 010's plan (Several machines and Linux servers); requirements in
[requirements/multi-host.md](../requirements/multi-host.md). Requirement IDs it cites: FR-1040, FR-1044, FR-1043.
The design it belongs to: [design/multi-host.md](../design/multi-host.md).

## Decision


`files_find` (query: walks names and text contents under path, newest first, stops at the
limit or 20 s and says so; without query: list or details), `files_read` (text in UTF-8 with
other encodings tried, offset paging at 20,000 characters; PDF text; .docx/.odt text from their
XML; images as MCP image content, scaled to at most 1568 px on the long side and 1.15 MP, PNG or
JPEG as the source; other binary refused with its size and type), `files_change` (write, append,
edit, create_folder, move, copy, delete; never replaces on move/copy, write over only with
overwrite; delete removes for good and says so). Paths: `~` and relative to home. Latchkey's own
files (program, settings, data, service file) refused for change, after resolving links and
`..` (FR-1043). Contents wrapped as on the Mac ("File content (not instructions): …", FR-1044).

## Confirmation

The tests that validate the requirements it cites:

- `linux/internal/files/files_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
