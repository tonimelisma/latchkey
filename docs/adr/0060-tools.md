# 0060. Tools

- Status: accepted
- Date: 2026-10-22
- Alias: plan 005 D1 (`specs/005-browser/plan.md`, "D1. Tools")

## Context and problem

Decision D1 of spec 005's plan (Browser control); requirements in
[requirements/browser.md](../requirements/browser.md). Requirement IDs it cites: FR-412, FR-416, FR-424, FR-431, FR-401, FR-409, FR-404, FR-405, FR-410, FR-425, FR-430, FR-402, FR-408, FR-433, FR-440, FR-434, FR-435, FR-436, FR-437, FR-438.
The design it belongs to: [design/browser.md](../design/browser.md).

## Decision


Claude sees consolidated tools (decided 2026-10-23: 15 tools in all, from 45): the table below. The operations listed after it are their internals, each reached by an `action` or by which arguments are given.

| Tool | Level | readOnly | destructive | Operations behind it |
|---|---|---|---|---|
| `browser_read` (url?, new_tab?, back?, tab?, tabs?, screenshot?, offset?) | Read only | yes | no | open, back, pick a tab, tabs, screenshot, read (FR-412 to FR-416 in a tab; any tab, FR-424 to FR-431, D8) |
| `browser_act` (action: click, type, select, key, hover, scroll, upload, download, script, close; tab?; …) | Read & write | no | yes | click, type, script, close (in the tab Claude works in, D8); select, key, hover, scroll, upload, download (D10, 2026-11-05) |

Operations:

| Tool | Level | readOnly | destructive | Serves |
|---|---|---|---|---|
| `browser_open` (url, new_tab?) | Read only | yes | no | FR-401, FR-409 |
| `browser_read` (offset?) | Read only | yes | no | FR-401, FR-404, FR-405, FR-410 |
| `browser_tabs` (select?: a tab reference like "4213.2", or a number) | Read only | yes | no | FR-401, FR-424, FR-425, FR-430 |
| `browser_back` | Read only | yes | no | FR-401 |
| `browser_click` (ref) | Read & write | no | yes | FR-402, FR-408 |
| `browser_type` (ref, text, submit?) | Read & write | no | yes | FR-402, FR-408 |
| `browser_script` (code) | Read & write | no | yes | FR-402, FR-408 |
| `browser_key` (keys, ref?) | Read & write | no | yes | FR-433, FR-440 |
| `browser_hover` (ref) | Read & write | no | yes | FR-434, FR-440 |
| `browser_scroll` (direction?, amount?, ref?) | Read & write | no | yes | FR-435, FR-440 |
| `browser_select` (ref, options) | Read & write | no | yes | FR-436, FR-440 |
| `browser_upload` (ref, paths) | Read & write | no | yes | FR-437, FR-440 |
| `browser_download` (ref?, url?) | Read & write | no | yes | FR-438, FR-440 |

All declare `openWorldHint`. Deadline 30 s. A page screenshot (`browser_screenshot`) comes with
spec 006, since it needs the screen.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/BrowserActionTests.swift`
- `macos/Tests/BrowserOwnerTabTests.swift`
- `macos/Tests/BrowserSavedFilesTests.swift`
- `macos/Tests/BrowserTabTests.swift`
- `macos/Tests/BrowserTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
