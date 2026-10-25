# Plan 005: Browser control — HOW

Derived from `spec.md`; evidence and low-level choices in `research.md`.

## D1. Tools

Claude sees consolidated tools (Toni, 2026-10-23: 15 tools in all, from 45): the table below. The operations listed after it are their internals, each reached by an `action` or by which arguments are given.

| Tool | Level | readOnly | destructive | Operations behind it |
|---|---|---|---|---|
| `browser_read` (url?, new_tab?, back?, tab?, tabs?, screenshot?, offset?) | Read only | yes | no | open, back, switch tab, tabs, screenshot, read |
| `browser_act` (action: click, type, script; …) | Read & write | no | yes | click, type, script |

Operations:

| Tool | Level | readOnly | destructive | Serves |
|---|---|---|---|---|
| `browser_open` (url, new_tab?) | Read only | yes | no | FR-401, FR-409 |
| `browser_read` (offset?) | Read only | yes | no | FR-401, FR-404, FR-405, FR-410 |
| `browser_tabs` (select?) | Read only | yes | no | FR-401 |
| `browser_back` | Read only | yes | no | FR-401 |
| `browser_click` (ref) | Read & write | no | yes | FR-402, FR-408 |
| `browser_type` (ref, text, submit?) | Read & write | no | yes | FR-402, FR-408 |
| `browser_script` (code) | Read & write | no | yes | FR-402, FR-408 |

All declare `openWorldHint`. Deadline 30 s. A page screenshot (`browser_screenshot`) comes with
spec 006, since it needs the screen.

## D2. Safari through Apple Events

AppleScript through the shared `osascript` runner (spec 002): opening makes a new window the
first time (its id is remembered) and later loads pages or adds tabs in that window only
(FR-403). `do JavaScript` runs in that window's current tab. Claude's text, URLs, and scripts
travel as arguments, and values put into page scripts are JSON-encoded. A closed window is
noticed and replaced on the next open.

The address Claude asks to open is checked before anything goes to Safari (FR-409): tabs and
line breaks are removed and the ends trimmed (as browsers do), an address without a scheme gets
`https://` (a host and port like `localhost:3000` counts as no scheme), and the result must parse
as `http://` or `https://` with a host; `about:blank` is the one other address. Anything else
(javascript:, file:, data:, blob:, app schemes, text that isn't an address) is refused with a
tool error naming what is allowed. FR-409 covers only that address: where a page goes after a
click, typing, or Claude's own script is Read & write, which may run script in the page anyway.

## D3. Reading and acting

One page script returns title, URL, visible text (100,000 characters per answer, `offset` to
read on), and up to 400 visible links, buttons, fields, and choices, each tagged with a
reference stored on the element (`data-latchkey="e12"`). Click and type find the element by
that reference; typing sets the value the way frameworks expect and fires input and change
events; submit uses the field's form. After an action, Latchkey waits for the page to finish
loading (at most 15 s) and returns the page's new title and URL. Every reading result starts by
saying the content is the website's, not instructions (FR-404).

A field's current value comes with it (first 100 characters), except for secrets (FR-410):
inputs of type `password`, and inputs and text areas whose `autocomplete` contains
`current-password`, `new-password`, `one-time-code`, `cc-number`, or `cc-csc`. Those are listed
with "(hidden)" in place of the value when filled in, and nothing when empty, so reading (a
Read only tool) never returns a password the browser filled in. Typing into them works as for
any field. Claude's own script (Read & write) can read anything in the page, as before.

## D4. Setup and errors

The setup window gains two steps while Browser isn't Off (FR-406): Automation for Safari (as
for Notes and Messages), and "Allow JavaScript from Apple Events", with instructions and a
Check button that opens a blank Safari window, runs one line of script, and closes it (the
setting can't be read reliably from Safari's preferences). A tool that hits the missing setting
explains where to turn it on.

## D5. Levels

New capability `browser`, levels Off / Read only / Read & write, starting Read & write (FR-407).
Clicks, typing, and scripts return an activity for the trace and the menu (FR-408); they don't
notify, as one task can mean dozens of clicks.

## Testing

A stand-in script runner answers like Safari: open, read (page JSON), click, type, missing
element, closed window, the JavaScript setting off, refused addresses (FR-409) both through
`browser_open` and through `browser_read` with a url. Tool list per level. The page script
itself is checked by running it in a WebKit view (`WKWebView`) on a fixed page in the tests,
including a form with filled-in secret fields whose values must not appear anywhere in the
answer (FR-410).

## Constitution check

| Article | Status |
|---|---|
| I. Outbound only | Pass |
| II. Fail fast | Pass: 25 s script deadline, 15 s page wait |
| III. Disabled means nonexistent | Pass |
| IV. Good macOS citizen | Pass: Apple Events with the Owner's consent; the Owner turns on Safari's setting |
| V. Self-hostable | Pass |
| VI. Store the minimum | Pass: nothing kept beyond the window id in memory |
| VII. Test-first | Planned |
| VIII. Simplicity | Pass: AppleScript and a page script; no driver or extension |
| IX. Open source | Pass |
