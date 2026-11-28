# 0070. Claude's pages in Latchkey's own browser, by name, with dialogs Claude answers (2026-11-15)

- Status: accepted
- Date: 2026-11-15
- Alias: plan 005 D11 (`specs/005-browser/plan.md`, "D11. Claude's pages in Latchkey's own browser, by name, with dialogs Claude answers (2026-11-15)")

## Context and problem

Decision D11 of spec 005's plan (Browser control); requirements in
[requirements/browser.md](../requirements/browser.md). Requirement IDs it cites: FR-443, FR-444, FR-451, FR-446, FR-421, FR-447, FR-448, FR-449, FR-450, FR-452, FR-441.
The design it belongs to: [design/browser.md](../design/browser.md).

## Decision


Serves FR-443 (amended), FR-444 to FR-451. Seen 2026-11-15 on Target: a "Remove item?" confirm
came after Claude's click had returned, so Safari's tab got Cancel or, once the page had its own
dialog functions back, waited on a dialog no one could see; and two other chats loaded their
pages (a menu, a complaint form) over the cart in Claude's one tab. The maintainer's choices are in
`docs/decisions.md` (2026-11-15); the options weighed are in `docs/research/2026-10-22-browser.md` ("Pages by name and
dialogs Claude answers").

- **Pages** (FR-444 to FR-446): `OwnPages` (main actor, one for the app) holds Claude's pages:
  name → a `LockedBrowser` (D7: off-screen `WKWebView`, its own memory-only cookie store, Safari's
  cookies taken again before every address Claude opens), and when each was last used. A name is
  "p" and four characters from `abcdefghjkmnpqrstuvwxyz23456789` (no look-alikes), random, unique
  among open pages, so a chat doesn't hit another's page by accident. `browser_read` with a url
  and no `page` makes a new page (refused with the list when 10 are open); with `page`, the
  address loads in that page. Every other call names its page with `page`, or, with none, uses
  the one page open; with none open, Claude is told to open one; with several, the call does
  nothing and answers the list (name, title, address, as website text). The minute timer that
  closes Claude's idle Safari tab (D2, D6) also closes pages unused for 30 minutes; a restart
  forgets all of them (FR-421). Each answer begins with FR-443's line, which names the page and
  says to pass it.
- **Where a call goes** (FR-447): a call that names an Owner's tab (`tab`) goes to Safari through
  D8 (a tab already picked with that reference keeps its pick and its guard; another one is
  picked); a call that names none goes to Claude's page. The browser tools set which, for the
  one call, in task-local values (`BrowserCapability.Asked`), so concurrent calls of different
  chats can't change each other's. Safari's own-tab code (D2, D6) stays only to close a tab or
  window an earlier version opened, by its idle rule; nothing opens one now. The Settings choice
  "Claude Opens Pages In" is removed.
- **Dialogs held for Claude** (FR-448, FR-449): WebKit hands each alert, confirm, and prompt to
  Latchkey's delegate with a reply to give later. An alert is answered at once and noted, as
  before. A confirm or prompt with no answer given in advance (FR-450) is held: Latchkey keeps
  the reply, and a script of Latchkey's that was running in the page (it can't finish while the
  page waits) is answered at once with the dialog instead of its result (its late result is
  dropped); a script that would start while one is held isn't started. A wait for a page to
  settle after a click ends when a dialog is held. The answer, not marked as an error, quotes
  the dialog (website text) and says how to answer: `browser_act` with `action: dialog`, `page`,
  and `confirm` true (OK) or false (Cancel), or `prompt_text`. Answering gives the reply, waits
  for the page to settle, and answers with the page (or the next dialog). A held dialog gets
  Cancel after 5 minutes (a timer per dialog), and before another address loads or the page
  closes; Claude is told at its next call on that page. Options weighed: answering confirms in
  advance only (before), holding alerts too (one possible answer: dismissing loses nothing).
- **Files** (FR-452): the navigation delegate's response check stops a main-frame load whose
  type WebKit can't show, or that is a PDF (an off-screen view never finished loading one, live
  check 2026-11-15), and keeps its address and type: the answer at once says it is a file and to
  save it with `download`; no script runs in that page; saving the page fetches the address
  itself (D10, with Safari's cookies). WebKit's own stop of such a load (error 102) counts as a
  file too, and WebKit's word of a load counts only for the load Latchkey waits for (a late
  error of an earlier one had ended or failed the next). Options weighed: letting WebKit show PDFs (needs a window,
  which would disturb the Owner), a longer wait (still a timeout), fetching every PDF at once
  (a download Claude didn't ask for).
- **Cookies per site** (FR-441, 2026-11-15): all of Claude's pages share one memory-only cookie
  store (`OwnPages`; dropped when every page closes at once), and a page takes Safari's cookies
  for a site (the cookies whose domain covers the host) when it goes there: before Claude's url
  loads (Safari's copy wins), and in the navigation-action check for any other site it goes to
  (a click, a redirect, a frame: only cookies the store lacks, so nothing changes under a form).
  The cookies are set all at once. Measured 2026-11-15: 3,500 cookies into a new store took 145 s
  one after another, 106 s all at once; since every new page copied them all, pages, pictures,
  and a PDF timed out in the live checks. Options weighed: one full copy per app run (still 100 s
  for the first page), copying in the background (pages signed out until it ends).
- **Answers given in advance** (FR-450): `DialogAnswer.confirm` is now optional (absent: not
  given). In Latchkey's own browser an answer given stays good for 5 s after the action returns,
  for that page only; in the Owner's Safari tabs it ends with the action, as D9 says.
- **Testing**: real WebKit views in unit tests (no network): a confirm after a click is held and
  told, answered OK and Cancel, given Cancel after the time limit (shortened in tests), and
  answered in advance up to 5 s after; two pages opened without names stay apart; naming,
  refusing with the list, the limit of 10, idle closing, and routing a call that names a tab to
  Safari (the stand-in).

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/BrowserOwnerTabTests.swift`
- `macos/Tests/LockedBrowserTests.swift`
- `macos/Tests/OwnPagesTests.swift`
- `macos/Tests/SignInRoutingTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
