# 0067. The Owner's tabs and windows (decided 2026-11-03)

- Status: accepted
- Date: 2026-11-03
- Alias: plan 005 D8 (`specs/005-browser/plan.md`, "D8. The Owner's tabs and windows (decided 2026-11-03)")

## Context and problem

Decision D8 of spec 005's plan (Browser control); requirements in
[requirements/browser.md](../requirements/browser.md). Requirement IDs it cites: FR-424, FR-431, FR-403, FR-416, FR-419, FR-404, FR-425, FR-427, FR-429, FR-423, FR-426, FR-428, FR-411, FR-430, FR-420.
The design it belongs to: [design/browser.md](../design/browser.md).

## Decision


Serves FR-424 to FR-431, and FR-403, FR-416, FR-419 as amended. The maintainer, answering a bug report
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
  times out while locked says Safari answers again once someone unlocks the Mac. While locked,
  each Safari script has 12 s instead of 25 s (2026-11-15), so a call of two or three scripts
  is told within the relay's 30 s. Opening a page
  uses Latchkey's own browser (FR-420) and makes Claude work in its own page again.
- **Answers** (FR-431): every answer from an Owner's tab starts by naming it ("In the owner's
  Safari tab 4213.2, not Claude's own").

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/BrowserActionTests.swift`
- `macos/Tests/BrowserOwnerTabTests.swift`
- `macos/Tests/BrowserTabTests.swift`
- `macos/Tests/LockedBrowserTests.swift`
- `macos/Tests/SafariCookiesTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
