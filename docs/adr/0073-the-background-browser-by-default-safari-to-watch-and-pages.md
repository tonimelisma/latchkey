# 0073. The background browser by default, Safari to watch, and pages' own saves (FR-474 to FR-477, 2026-11-24)

- Status: accepted
- Date: 2026-11-23
- Alias: plan 005 D14 (`specs/005-browser/plan.md`, "D14. The background browser by default, Safari to watch, and pages' own saves (FR-474 to FR-477, 2026-11-24)")

## Context and problem

Decision D14 of spec 005's plan (Browser control); requirements in
[requirements/browser.md](../requirements/browser.md). Requirement IDs it cites: FR-474, FR-477, FR-452.
The design it belongs to: [design/browser.md](../design/browser.md).

## Decision


Serves FR-474 to FR-477 (problem reports 2026-11-24; the maintainer's answers in the spec). `browser_open`
no longer reads Safari's sign-in cookies (`OwnPages.signedIn` and `inSafari` are gone): it opens
a Safari page (D13's `openTab`) only when the call has `show_in_safari` and `isLocked()` is false;
while locked it opens Latchkey's own page with a note. The public page tool is `browser_look`
(the internal operation keeps its name `browser_read`); every text Claude reads names
`browser_look`.

`LockedBrowser` is also a `WKDownloadDelegate`. The navigation-action check answers `.download`
for an action WebKit marks `shouldPerformDownload` (a link with `download`), and the response
check answers `.download` for a main-frame attachment (`Content-Disposition: attachment`) or a
type WebKit can't show (not a PDF, which stays FR-452's file page), both only while `mayDownload`:
during Claude's action (`acting`) or within `downloadWindow` (5 s) after it ends (`end()` sets
`actedUntil`; opening a page clears it). Else the action is cancelled with a note. The
destination is `BrowserDownloads.free(name)` in Downloads, the name from
`BrowserDownloads.name` (disposition, then WebKit's suggested name). WebKit writes to a staging
file `Downloads/.latchkey-saving-<UUID>.part`; on finish it is moved to a free name
(`BrowserDownloads.move`, retrying when a name is taken meanwhile) and quarantined; on failure or
stop only the staging file is removed (also in `cancel`'s completion), and staging files over an
hour old are swept at the next save. At most 5 saves per action (`savesPerAction`), from the main
frame or a frame of the page's own host; the rest are refused and counted. A watcher (every
100 ms) stops saves past 500 MB together (`directLimit`) or 10 minutes; closing the page stops
them. A load the response check turned into a save ends with WebKit's 102, which is then not
FR-452's file page (`loadBecameSave`), and `click`'s fallback load is skipped once the click
started a save. Notes (at most 5, plus refused and still-arriving lines) go to Claude through
`told`, under a header saying names in «» are the website's, after it waits up to 20 s for saves
started since the last action began. Security review of the diff (2026-11-24, a review subagent):
the double save and stuck file page, removing others' files via a raced name, no cap on saves,
page text in Latchkey's voice, waits on old saves, and the cap's overshoot were fixed as above.

Options weighed for where the save's outcome is told: (a) in the next answer through `told`,
after waiting for running saves (chosen: every answer from the page already goes there, and a
script's own answer is the script's value); (b) a wait inside each action for a save that may
start (rejected: a fixed wait for something that may never come, against
`.claude/rules/tool-design.md`); (c) a separate tool to list saves (rejected: one more step for
Claude, and the answer has the path anyway).

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/BrowserSavedFilesTests.swift`
- `macos/Tests/OwnPagesTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
