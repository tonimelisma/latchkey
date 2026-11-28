# 0061. Safari through Apple Events

- Status: accepted
- Date: 2026-10-22
- Alias: plan 005 D2 (`specs/005-browser/plan.md`, "D2. Safari through Apple Events")

## Context and problem

Decision D2 of spec 005's plan (Browser control); requirements in
[requirements/browser.md](../requirements/browser.md). Requirement IDs it cites: FR-403, FR-411, FR-418, FR-409.
The design it belongs to: [design/browser.md](../design/browser.md).

## Decision


(Since 2026-11-15, D11: Claude's own pages are Latchkey's own browser's. The window and tab of
Claude's own in Safari described in D2 and D6, their memory file, the Settings choice, and the
idle closing are removed with their code; the scripts, the survey, the mark and its check, and
the navigation rules below now serve the Owner's tabs, D8, as `SafariBrowser`.)

AppleScript through the shared `osascript` runner (spec 002): opening makes a new window the
first time (its id is remembered) and later loads pages or adds tabs in that window only
(FR-403). `do JavaScript` runs in that window's current tab. Claude's text, URLs, and scripts
travel as arguments, and values put into page scripts are JSON-encoded. A closed window is
noticed and replaced on the next open. Each use notes the time; a minute timer closes the
window (by its id, never another) once it is 30 minutes unused, and forgets it (FR-411). The
id, the last use, and which run of Safari it belongs to (process id and launch time) are kept in
`safari-window.json` in the support folder, so a restarted Latchkey picks the window up again,
but only while the same Safari runs: after Safari restarts, the id could be one of the Owner's.
So each minute the timer also notes the addresses of Claude's own window's tabs (and forgets a
window the Owner closed). After Safari restarts, that window is found again when exactly one
visible window has exactly those tabs, tried each minute and at Claude's next page in the first
5 minutes after Safari starts, while it brings its windows back (never starting Safari), then
given up; the tab list is cleared whenever Claude's window changes. Known by its addresses alone, it is
never used for Claude's pages: it is only closed once 30 minutes have passed since Claude last
used it, and only if it is still the one window with those tabs; otherwise it is left open and
noted. Claude's tab in the Owner's window has lost its mark after a restart, so it is left alone;
when some tab shows Claude's last address, a Left Behind entry says Latchkey lost track of it
(FR-418).

The address Claude asks to open is checked before anything goes to Safari (FR-409): tabs and
line breaks are removed and the ends trimmed (as browsers do), an address without a scheme gets
`https://` (a host and port like `localhost:3000` counts as no scheme), and the result must parse
as `http://` or `https://` with a host; `about:blank` is the one other address. Anything else
(javascript:, file:, data:, blob:, app schemes, text that isn't an address) is refused with a
tool error naming what is allowed. FR-409 covers only that address: where a page goes after a
click, typing, or Claude's own script is Read & write, which may run script in the page anyway.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/BrowserTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
