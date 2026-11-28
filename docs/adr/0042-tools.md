# 0042. Tools

- Status: accepted
- Date: 2026-10-22
- Alias: plan 003 D1 (`specs/003-files/plan.md`, "D1. Tools")

## Context and problem

Decision D1 of spec 003's plan (Files); requirements in
[requirements/files.md](../requirements/files.md). Requirement IDs it cites: FR-211, FR-216, FR-217, FR-212, FR-214, FR-213.
The design it belongs to: [design/files.md](../design/files.md).

## Decision


Claude sees consolidated tools (decided 2026-10-23: 15 tools in all, from 45): the table below. The operations listed after it are their internals, each reached by an `action` or by which arguments are given.

| Tool | Level | readOnly | destructive | Operations behind it |
|---|---|---|---|---|
| `files_find` (query?, path?, hidden?, limit) | Read only | yes | no | with query: search; a folder: list; a file: info |
| `files_read` (path, offset?) | Read only | yes | no | read |
| `files_change` (action: write, append, edit, create_folder, move, copy, trash; …) | Read & write | no | yes | write, edit, create folder, move, copy, trash |

Operations:

| Tool | Level | readOnly | destructive | Serves |
|---|---|---|---|---|
| `files_search` (query, folder?, limit) | Read only | yes | no | FR-211 |
| `files_list` (path, hidden?) | Read only | yes | no | FR-211 |
| `files_info` (path) | Read only | yes | no | FR-211 |
| `files_read` (path, offset?) | Read only | yes | no | FR-211, FR-216, FR-217 |
| `files_write` (path, text, overwrite?, append?) | Read & write | no | yes | FR-212, FR-214 |
| `files_edit` (path, find, replace) | Read & write | no | yes | FR-212 |
| `files_create_folder` (path) | Read & write | no | no | FR-212 |
| `files_move` (from, to) | Read & write | no | no | FR-212, FR-214 |
| `files_copy` (from, to) | Read & write | no | no | FR-212, FR-214 |
| `files_trash` (path) | Read & write | no | yes | FR-212, FR-213 |

Deadlines: search 30 s, reads 30 s (cloud downloads), changes 10 s.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/FilesTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
