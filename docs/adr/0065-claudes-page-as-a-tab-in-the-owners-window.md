# 0065. Claude's page as a tab in the Owner's window (2026-10-29)

- Status: accepted
- Date: 2026-10-29
- Alias: plan 005 D6 (`specs/005-browser/plan.md`, "D6. Claude's page as a tab in the Owner's window (2026-10-29)")

## Context and problem

Decision D6 of spec 005's plan (Browser control); requirements in
[requirements/browser.md](../requirements/browser.md). Requirement IDs it cites: FR-403, FR-411, FR-418, FR-417, FR-413, FR-414, FR-416, FR-415.
The design it belongs to: [design/browser.md](../design/browser.md).

## Decision


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

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/BrowserTabTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
