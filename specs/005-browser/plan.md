# Plan 005: Browser control — HOW

Derived from `spec.md`; evidence and low-level choices in `research.md`.

## D1. Tools

Claude sees consolidated tools (Toni, 2026-10-23: 15 tools in all, from 45): the table below. The operations listed after it are their internals, each reached by an `action` or by which arguments are given.

| Tool | Level | readOnly | destructive | Operations behind it |
|---|---|---|---|---|
| `browser_read` (url?, new_tab?, back?, tab?, tabs?, screenshot?, offset?) | Read only | yes | no | open, back, pick a tab, tabs, screenshot, read (FR-412 to FR-416 in a tab; any tab, FR-424 to FR-431, D8) |
| `browser_act` (action: click, type, script, close; tab?; …) | Read & write | no | yes | click, type, script, close (in the tab Claude works in, D8) |

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

## D7. While the Mac is locked: a browser of Latchkey's own (FR-420 to FR-422, Toni 2026-11-02)

Seen live 2026-11-01: with the Mac locked, Safari answers the first script and then no more (every
script times out). Latchkey never gets around the lock (spec 001 FR-661). Tried live while locked
on 2026-11-02: an off-screen `WKWebView` in a process of its own loaded a page, ran its scripts,
went to an address and back, and drew a full picture of the page (`takeSnapshot`); a link
clicked by a script didn't navigate there, so the click follows the link's address itself.
Options Toni was shown: nothing while locked; the built-in browser for public pages; the same
with Safari's sign-ins. Chosen: with Safari's sign-ins. `LockedBrowser` (main actor) is one
off-screen `WKWebView` with a `.nonPersistent()` data store, so nothing reaches the disk; when it
is made it reads Safari's `Cookies.binarycookies` (Full Disk Access, which setup asks for;
`SafariCookies`: the long-known format, bounds-checked, expired ones left out; read live
2026-11-02: all 3,530 cookies of 1,393 sites) into that store. The browser tools ask
`BrowserCapability.lockedRoute` on each call: locked, the built-in browser; unlocked, it is
discarded with its cookies and Safari answers. It runs the same `PageScripts`, so answers look
the same; one page, no tabs; screenshots are its own drawing (no screen permission needed).
Since 0.8.79: a page's dialogs are answered by Latchkey (alert dismissed, confirm Cancel so a page
never gets a yes, prompt nothing) and told to Claude before the next page; a link or script that
opens a new window opens in the one page; the view identifies as the installed Safari (Google's
sign-in refuses embedded browsers; checked live locked: signed in to Google and GitHub); a load
cancelled by the next one or back from memory (-999) isn't a failure; a page that changes without
loading (pushState) counts as loaded once its address changed. Risks: Safari's cookie file format isn't documented (a change shows as no sign-ins, not as a
failure); a site that ties a session to Safari itself may ask to sign in.

## D8. The Owner's tabs and windows (Toni, 2026-11-03)

Serves FR-424 to FR-431, and FR-403, FR-416, FR-419 as amended. Toni, answering a bug report
(`browser_read tabs:true` said "Claude's Safari page isn't open" when asked about his tabs):
"Claude needs to be able to access my tabs and windows just like its own."

- **The list** (FR-424, FR-431): one AppleScript (`allTabs`) walks Safari's windows front to
  back, keeping those with a current tab (browser windows), and answers for each its id, the
  number of its front tab, and each tab's number, title, and address (tabs and line breaks in
  titles become spaces). No page script runs for the list. Latchkey adds which tab is Claude's
  (its tab found as in D6, or the front tab of Claude's own window) and which one Claude works
  in. Each tab is named by a reference, the window's Safari id and the tab's number:
  `4213.2`. The answer starts by saying titles and addresses are the websites' (FR-404), stays
  within Claude's result size (titles cut at 150 characters, addresses at 400; tabs past the
  limit counted), and ends by saying how to pick one.
- **Picking a tab** (FR-425): `browser_read` with `tab` (a reference, or a bare number: that
  tab of the window holding Claude's page, else of the front window), or `browser_act` with
  `tab` before its action. A tab that is Claude's own tab, or a tab of Claude's own window (where
  Claude's window switches its front tab, as before), makes Claude work in its own page. Any
  other tab becomes the tab Claude works in: one script (`tabPick`) checks the window and tab
  are there, puts Claude's mark (D6) on its page with a token of its own, and answers the
  window's tab count and the tab's address; nothing comes forward (FR-427).
- **Working in it** (FR-425, FR-427, FR-429): the tab is kept as Claude's tab is (window id,
  position, tab count, address, token), and every operation that works in Claude's tab works in
  it, through the same survey, guard, scripts, and navigation rules (D6): the same-site rule for
  a page's own note, and since 2026-11-01 the clicked link's address on any site. The one
  difference in the guard: when Safari let no script mark the tab's page when it was picked (an
  empty tab, Safari's own pages), the tab passes while it shows the address it had then; that
  address never changes afterwards, so no navigation can move it. When the tab isn't surely
  found, Latchkey stops working in it, touches nothing, notes nothing as left behind (the tab
  is the Owner's), and tells Claude to list the tabs again; the rest of that call never falls
  back to Claude's own page. A picture follows FR-423 as for Claude's tab: an Owner's tab already in front is
  pictured at once; one behind another is switched forward only while its window can't be seen.
- **Opening a page** (FR-426): always in Claude's own tab or window (D2, D6); Claude then works
  in its own page again.
- **Closing** (FR-428): `browser_act close` closes the tab Claude works in, through the guard
  without the navigation allowance; an Owner's tab closed this way is the Owner's request, so it
  is not a Left Behind entry. Then Claude works in its own page again.
- **How long** (FR-425): the tab Claude works in is kept in memory only (not in
  `safari-window.json`): a restart of Latchkey forgets it, and so does 30 minutes unused (the
  idle timer of FR-411, which only forgets it; it never closes an Owner's tab).
- **Locked** (FR-430): the Owner's tabs exist only in Safari, so while the Mac is locked the
  list, a pick, and every call while Claude works in an Owner's tab still go to Safari; only
  Claude's own page is Latchkey's own browser (D7). The list also names that browser's page.
  Safari stopped answering while locked on 2026-11-01 but answered the list three times and a
  page script three times while locked on 2026-11-03 (research.md), so Latchkey tries: a list
  Safari doesn't answer says the Owner's tabs need the Mac unlocked, and any other call that
  times out while locked says Safari answers again once someone unlocks the Mac. Opening a page
  uses Latchkey's own browser (FR-420) and makes Claude work in its own page again.
- **Answers** (FR-431): every answer from an Owner's tab starts by naming it ("In the owner's
  Safari tab 4213.2, not Claude's own").

## D9. A page's own dialogs (FR-432, Toni 2026-11-03)

Found by trying it in real Safari (2026-11-03, a background tab Latchkey's way, with a page that
shows an alert): while a page waits on its own dialog, every `do JavaScript` in that tab, and
even its `text` and `source`, waits for Apple Events' time limit (-1712); its name and URL still
answer, and so do other tabs at once, also right after (Safari as a whole never stalled).
Setting the tab's URL replaced the page in 0.2 s and closing it worked. Accessibility shows no
sheet for a background tab's dialog (it appears when the tab comes to the front). This is the
most likely cause of the locked-Mac stalls seen on 2026-11-01 (a dialog no one could see or
answer); the time limit was 25 s (ScriptRunner).

- Answers in the page: each page script starts with `PageScripts.dialogAnswers`, which replaces
  `alert`, `confirm`, and `prompt` in the page and the frames it can reach (once per document)
  with ones that answer at once as Claude's action says (default Cancel, no text) and note what
  they said; the same AppleScript run then takes the notes (`takeDialogs`, 2 s limit) and they
  come with the answer, worded as in Latchkey's own browser (`PageScripts.dialogNote`, at most
  5, 200 characters each, no «»). Latchkey's own browser answers through WebKit's delegate the
  same way. `browser_act` takes `confirm` (true: OK) and `prompt_text`, for that action only.
  A page can restore its own functions; then its dialog waits, and the next check below says so.
- A page that already waits (its dialog came before the answers were in, e.g. at load): every
  check of a page (the mark check in the survey and the guard, picking, putting a tab back) has
  a 2 s limit; on -1712 the survey marks the tab waiting, and a script refuses at once
  (`dialogWaiting`). The tab is still Claude's when it is where it was, the window has as many
  tabs, and it shows its last address; it can then be loaded over (`tabLoad`) or closed, with
  that address standing in for the mark. Claude's own window gets a 2 s `do JavaScript "1"`
  first. The Owner's tab is left alone: its dialog shows when he brings the tab forward.
- Options weighed: a shorter time limit for every script (wrongly fails slow pages; still a
  wait), refusing the Owner's tabs while locked (refuses what works, and dialogs happen unlocked
  too), Accessibility checks for sheets (they don't show a background tab's dialog).

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

For the Owner's tabs (D8), the same stand-in Safari lists every window's tabs, picks one,
reads, clicks, types, runs a script, goes back, takes a picture, and closes it while the tab in
front stays in front; a tab that moved, closed, or was replaced between picking and acting is
left alone and Claude is told to list again; opening a page goes back to Claude's own tab;
30 minutes unused forgets the pick; while locked the list and a picked tab still go to Safari, and a silent Safari is said plainly. The tools' answers name the
tab and mark the list as the websites'.

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
parts with a working offset, and (2026-11-03) another tab of the check's own window is listed,
picked, read, clicked, and closed while the tab in front stays in front. With
`LATCHKEY_READ_OWNER_TAB=1` it also lists the Owner's real tabs and reads one (reading only). It runs from a terminal that may control Safari, not from the
test host: the test host is its own app to macOS, and its first Apple Event to Safari opens an
Automation prompt, during which Safari answers no window or tab scripting from anyone (seen
2026-10-29: the prompt waited behind the locked screen and blocked every Safari script).

## Constitution check

| Article | Status |
|---|---|
| I. Outbound only | Pass |
| II. Fail fast | Pass: 25 s script deadline, 15 s page wait |
| III. Disabled means nonexistent | Pass |
| IV. Good macOS citizen | Pass: Apple Events with the Owner's consent; the Owner turns on Safari's setting; WebKit's public API while locked (Safari's cookie file is read under Full Disk Access; its format is undocumented) |
| V. Self-hostable | Pass |
| VI. Store the minimum | Pass: the window id, and for a tab its position, count, address, and token, deleted when it closes; the Owner's tab Claude works in, in memory only; while locked, a copy of Safari's cookies in memory only, dropped at unlock |
| VII. Test-first | Planned |
| VIII. Simplicity | Pass: AppleScript and a page script; no driver or extension |
| IX. Open source | Pass |
