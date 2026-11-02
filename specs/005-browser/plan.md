# Plan 005: Browser control — HOW

Derived from `spec.md`; evidence and low-level choices in `research.md`.

## D1. Tools

Claude sees consolidated tools (Toni, 2026-10-23: 15 tools in all, from 45): the table below. The operations listed after it are their internals, each reached by an `action` or by which arguments are given.

| Tool | Level | readOnly | destructive | Operations behind it |
|---|---|---|---|---|
| `browser_read` (url?, new_tab?, back?, tab?, tabs?, screenshot?, offset?) | Read only | yes | no | open, back, switch tab, tabs, screenshot, read (FR-412 to FR-416 in a tab) |
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

## D3. Reading and acting

One page script returns title, URL, visible text (40,000 characters from `offset`), and up to
400 visible links, buttons, fields, and choices, each tagged with a reference stored on the
element (`data-latchkey="e12"`). The answer as a whole stays within Claude's result size (40,000
characters, FR-405; 2026-10-29: a Wikipedia article came back as 71,455): the list of links,
buttons, and fields takes at most 20,000 (a link on the page's own host shows its path only;
those that don't fit are counted, and a script can find them), the text gets the rest, and the
answer names the offset to read on from ("Characters 0–24518 of 70184. Read on with browser_read
and offset 24518."). Offsets count as JavaScript does (UTF-16). `browser_read` with a url and
an offset opens the page and reads it from the offset. Click and type find the element by
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

## D6. Claude's page as a tab in the Owner's window (2026-10-29)

Serves FR-403, FR-411 to FR-418. Settings → What Claude Can Do → Browser has "Claude Opens Pages
In": "A Tab in Your Safari Window" (default) or "A Window of Its Own" (D2, as before). The choice
is the user default `browserPlace` (`tab` or `window`), read each time Claude opens a page; the
other operations follow whichever Claude has. A changed choice closes Claude's previous tab or
window at the next page Claude opens (FR-417).

- **Opening** (FR-413, FR-414): `make new tab at end of tabs` of the first Safari window that has
  a current tab (front to back), without making it the current tab, so the Owner's tab stays in
  front. With no such window, a new window, found as in D2 by the id that wasn't there before.
  Later pages load in that tab (`set URL`), also with `new_tab` (FR-416).
- **Knowing Claude's tab**: Safari's tabs have no id; only a position. Latchkey keeps the window
  id, the tab's position, the window's tab count, the tab's last address, and a random token.
  Before every script it puts the token on Claude's page as a hidden property
  (`window.__latchkeyTab`, not enumerable). Before each use, one script surveys the window: for
  each tab only whether it shows Claude's last address and, for the tab at Claude's position and
  tabs at that address only, whether it carries the token ("yes"/"no"). Nothing else of the
  Owner's tabs is read, and no script of Claude's runs in them. Latchkey then picks (pure Swift,
  `TabSurvey.pick`): the tab at Claude's position if marked; else, while a page Claude loaded is
  loading (a new page has no mark yet), the tab at that position if the tab count is the same and
  the tab shows that page's address; else a marked tab at Claude's last address (tabs moved).
  Otherwise none: Latchkey forgets the tab, notes it lost track of it (FR-418), and Claude is told
  its page isn't open.
- **Claude's own navigation** (security review, 2026-10-29): "a page Claude loaded is loading" is
  its own record, not the time of Claude's last use, which every Apple Event (the survey too)
  refreshes, so it could stay open for ever. It starts when Claude opens a page (the address
  asked for) and when Claude's marked page reports that it is going to another page: the mark
  script also listens for the Navigation API's `navigate` event, and every script in Claude's
  tab ends by taking the address it noted (clicks, forms, `back`). Real Safari (2026-10-29)
  times this differently from the WebKit view: `location.href` fires the event during the
  script and the page is gone by the next `do JavaScript`, and a link, a form, or back fires it
  only after the script has returned, usually after the new page has replaced the old one. So
  the note is taken in the same run as the script (`PageScripts.inTab`); the click script also
  answers the address of the link it clicked when the link opens in the same tab, read after the
  page's click handlers, and the back script the address of the history entry it goes to
  (Navigation API `entries()`); and after a click, typing, or back the acting AppleScript asks
  for the note again every 0.05 s for up to about 0.6 s, stopping at a note, at a page without
  Latchkey's note (the new page answers `null`), or when the window's tab count changed. All
  three are the page's word and count only as notes do (same site, one per action, only in
  Claude's click, typing, or back). The note is the event's
  destination only, kept in the listener's own variable and read through a getter that can't be
  changed (page code can't write it; a note the page put there first is ignored); it comes back
  JSON-encoded on one line, the AppleScript removes line breaks from it, and Latchkey uses it
  only when it decodes to one http(s) address without spaces. One note counts per action of
  Claude's (each tool call), and the start is set at most once per action: in an action that
  opened a page, a note only adds its address. It lasts the settle limit plus 1 s (16 s) from
  that moment, and only
  for those addresses, in the spellings a redirect to https, www., or a final / gives. A page
  that goes elsewhere (other redirects, a navigation the page starts later without a script of
  Claude's seeing it) makes Latchkey lose the tab: it stays open and is named (FR-418).
- **Checking again before acting** (security review, 2026-10-29): every script that acts on
  Claude's tab (script, load, bring forward, close) starts by checking, in the same script, that
  the tab count is the same and the tab at Claude's position carries the mark (the yes/no check)
  or, during Claude's navigation, shows one of its addresses. Otherwise it does nothing and
  answers "moved"; Latchkey surveys again once. The mark is only put on a tab that passed this
  check. Bringing the Owner's tab back after a screenshot also needs Claude's tab, still
  marked, in front.
- **Screenshot** (FR-415): one script remembers the tab in front, brings Claude's tab forward, and
  answers its title; after 0.3 s for Safari to draw it, the window is captured as before; then a
  script brings the remembered tab back only if Claude's tab is still in front.
- **Idle close** (FR-411): Claude's tab is closed by the same survey and check, with no
  navigation allowance, so an unmarked tab at its position is never closed; when the check fails,
  the lost tab is noted. `safari-window.json` gains the tab (position,
  count, address, token), so a restarted Latchkey closes it too, in the same run of Safari.
- **Tabs** (FR-416): the tab list shows Claude's tab alone as tab 1; switching to another number
  is refused with a hint to open a page instead.

## Testing

A stand-in script runner answers like Safari: open, read (page JSON), click, type, missing
element, closed window, the JavaScript setting off, refused addresses (FR-409) both through
`browser_open` and through `browser_read` with a url. Tool list per level. The page script
itself is checked by running it in a WebKit view (`WKWebView`) on a fixed page in the tests,
including a form with filled-in secret fields whose values must not appear anywhere in the
answer (FR-410).

For a tab (D6), a stand-in Safari with windows and tabs records which tabs ran which script:
Claude's tab opens behind the Owner's, is found again after the Owner closes a tab before it, is
never replaced by an Owner's tab in its place (also at the same address), comes forward for a
screenshot and goes back (also when the shot fails), closes when idle (also after a restart), and
the setting switches between tab and window, an Owner's tab slides into Claude's place between
the survey and the action (for reading, opening, screenshot, and closing), Latchkey's own scripts
keep running past the navigation allowance, and a click goes to another site. The Owner's tabs
never run a script of Claude's, get the mark, load a page, close, or come forward.
`TabSurvey.pick` has its own table of cases; the mark is checked in a WebKit view. Every new
AppleScript compiles (`ScriptSyntaxTests`).

The stand-in Safari times notes as real Safari does (2026-10-29): a link's and back's note never
arrives (the page is gone first), a button's arrives only to the acting script's wait, a
script's only in its own run. Tests: a same-site link, a link to another site (since
2026-11-01: the clicked link's address counts on any site), a button, and back keep the tab; a
note of another site and a script that navigates lose it; a note in the click script's own run
counts. The WebKit view checks the note taken in the script's own run, `null` on a page
without the note, and the addresses the click and back scripts answer. Paging: a page like
the Wikipedia article stays within Claude's result size and names the offset, and a url with
an offset reads from it.

What only real Safari can show is checked by `macos/scripts/safari-check.sh`: Latchkey's own
`SafariBrowser` against real Safari, in a window the check opens and closes, never touching
the Owner's: a same-site click keeps the tab and the new page reads (and back, and a second
click), a cross-site click keeps it (since 2026-11-01), a script's navigation loses it as
designed, a long page comes in
parts with a working offset. It runs from a terminal that may control Safari, not from the
test host: the test host is its own app to macOS, and its first Apple Event to Safari opens an
Automation prompt, during which Safari answers no window or tab scripting from anyone (seen
2026-10-29: the prompt waited behind the locked screen and blocked every Safari script).

## Constitution check

| Article | Status |
|---|---|
| I. Outbound only | Pass |
| II. Fail fast | Pass: 25 s script deadline, 15 s page wait |
| III. Disabled means nonexistent | Pass |
| IV. Good macOS citizen | Pass: Apple Events with the Owner's consent; the Owner turns on Safari's setting |
| V. Self-hostable | Pass |
| VI. Store the minimum | Pass: the window id, and for a tab its position, count, address, and token, deleted when it closes |
| VII. Test-first | Planned |
| VIII. Simplicity | Pass: AppleScript and a page script; no driver or extension |
| IX. Open source | Pass |
