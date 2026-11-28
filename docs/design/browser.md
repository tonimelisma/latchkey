# Browser control: design

GOVERNS: `macos/App/Browser/`

Spec 005's plan (migrated from `specs/005-browser/plan.md`, titled "Plan 005: Browser control — HOW"). What it must do:
[requirements/browser.md](../requirements/browser.md). Each decision Dn is an ADR, linked
where the decision stood.

Derived from `docs/requirements/browser.md`; evidence and low-level choices in `docs/research/2026-10-22-browser.md`.

## D1. Tools

Decision record: [ADR 0060](../adr/0060-tools.md).

## D2. Safari through Apple Events

Decision record: [ADR 0061](../adr/0061-safari-through-apple-events.md).

## D3. Reading and acting

Decision record: [ADR 0062](../adr/0062-reading-and-acting.md).

## D4. Setup and errors

Decision record: [ADR 0063](../adr/0063-setup-and-errors.md).

## D5. Levels

Decision record: [ADR 0064](../adr/0064-levels.md).

## D6. Claude's page as a tab in the Owner's window (2026-10-29)

Decision record: [ADR 0065](../adr/0065-claudes-page-as-a-tab-in-the-owners-window.md).

## D7. While the Mac is locked: a browser of Latchkey's own (FR-420 to FR-422, decided 2026-11-02)

Decision record: [ADR 0066](../adr/0066-while-the-mac-is-locked-a-browser-of-latchkeys-own.md).

## D8. The Owner's tabs and windows (decided 2026-11-03)

Decision record: [ADR 0067](../adr/0067-the-owners-tabs-and-windows.md).

## D9. A page's own dialogs (FR-432, decided 2026-11-03)

Decision record: [ADR 0068](../adr/0068-a-pages-own-dialogs.md).

## D10. Keys, hover, scrolling, lists, files, and pictures without the screen (2026-11-05)

Decision record: [ADR 0069](../adr/0069-keys-hover-scrolling-lists-files-and-pictures-without-the.md).

## D11. Claude's pages in Latchkey's own browser, by name, with dialogs Claude answers (2026-11-15)

Decision record: [ADR 0070](../adr/0070-claudes-pages-in-latchkeys-own-browser-by-name-with-dialogs.md).

## D12. Sign-in cookies in Latchkey's log (FR-453, FR-454, 2026-11-15)

Decision record: [ADR 0071](../adr/0071-sign-in-cookies-in-latchkeys-log.md).

## D13. Signed-in sites in Safari while unlocked (FR-455 to FR-459, 2026-11-15)

Decision record: [ADR 0072](../adr/0072-signed-in-sites-in-safari-while-unlocked.md).

## D14. The background browser by default, Safari to watch, and pages' own saves (FR-474 to FR-477, 2026-11-24)

Decision record: [ADR 0073](../adr/0073-the-background-browser-by-default-safari-to-watch-and-pages.md).

## D15. Real mouse and keyboard in Latchkey's own browser (FR-478 to FR-489, 2026-11-25)

Decision record: [ADR 0074](../adr/0074-real-mouse-and-keyboard-in-latchkeys-own-browser.md).

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

The actions of D10 (2026-11-05) run on a page of their own in a WebKit view: keys send a
form, move the focus, clear a field, change a list, and reach the page's handlers; hover opens a
menu that opens on hover; the page and a part of it scroll; lists (one, several, one the page
builds) are chosen and a missing option names those there are; files go into a field, a hidden
field (one file only), and a drop place; a file the page made and a `data:` link are fetched,
taken once, and a too-big one refused; the picture copy keeps typed values and choices, never a
password, and no script. The same in Latchkey's own browser, and a copy drawn into a picture.
The tools: `browser_act` takes each action and records it; an unknown key, a missing file, and
a wrong direction are refused; a download is saved under the server's name in a test folder,
with the path in the answer, and a site's error or a too-big file saves nothing. Names, saving
never over another file, the quarantine mark, attachments, and the script file have their own
tests.

What only real Safari can show was checked by macos/scripts/safari-check.sh (retired
2026-11-26, spec 016 D5; its checks move to the sandbox Mac, `relay/e2e/sandbox-checks.md`): Latchkey's own
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
| II. Fail fast | Pass: 25 s script deadline, 15 s page wait; a file saved through the page waits at most 20 s, one Latchkey fetches at most 20 s (and only when the page answered sooner) |
| III. Disabled means nonexistent | Pass |
| IV. Good macOS citizen | Pass: real events only into Latchkey's own never-shown view, never the screen or the pointer, the window counted as front only during Claude's call (D15); Apple Events with the Owner's consent; the Owner turns on Safari's setting; WebKit's public API while locked (Safari's cookie file is read under Full Disk Access; its format is undocumented) |
| V. Self-hostable | Pass |
| VI. Store the minimum | Pass: the window id, and for a tab its position, count, address, and token, deleted when it closes; the Owner's tab Claude works in, in memory only; while locked, a copy of Safari's cookies in memory only, dropped at unlock; a long page script (an attachment) in a 0600 file removed right after; saved files go to the Owner's Downloads, where he keeps them |
| VII. Test-first | Planned |
| VIII. Simplicity | Pass: AppleScript and a page script; no driver or extension; in Latchkey's own browser AppKit's own events handed to the view (D15) |
| IX. Open source | Pass |
