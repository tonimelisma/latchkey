# 0072. Signed-in sites in Safari while unlocked (FR-455 to FR-459, 2026-11-15)

- Status: accepted
- Date: 2026-11-15
- Alias: plan 005 D13 (`specs/005-browser/plan.md`, "D13. Signed-in sites in Safari while unlocked (FR-455 to FR-459, 2026-11-15)")

## Context and problem

Decision D13 of spec 005's plan (Browser control); requirements in
[requirements/browser.md](../requirements/browser.md). Requirement IDs it cites: FR-455, FR-459, FR-439.
The design it belongs to: [design/browser.md](../design/browser.md).

## Decision


`OwnPages` holds each page as `.own(LockedBrowser)` or `.safari(SafariBrowser)`. A Safari page
has a `SafariBrowser` of its own (`sibling()`: the same script runners and limits), so pages of
different chats never share a picked tab, and the owner's tabs keep theirs. `openTab` makes a
tab at the end of the front browser window (`make new tab at end of tabs`, which leaves the
current tab as it is), picks it with a new mark, and waits for the page like any navigation of
Claude's (the tab is taken unmarked while it shows the address it is loading); `load` loads an
address in it (`Script.tabLoad`, guarded like every action). `browser_open` decides: a page the
call names that is a Safari page loads there; otherwise, while unlocked and `signedIn(host)`
(a sign-in cookie of `CookieWatch.isSignIn` lasting over a day in Safari's file), a Safari page;
else Latchkey's own browser. `BrowserTools.asked` resolves the page name: for a Safari page it
sets `Asked.safari` and `Asked.safariName`, `route` then answers nil, and every handler's Safari
calls go through `here(browser)`, the page's driver. `LockedBrowser` takes Safari's cookies only
when `mayCopy()` (from `OwnPages`: locked), which also marks the store as holding copies; the
next call after unlock removes the store's cookies (`removeData`) and the pages' taken sites.
A picture drawn in Latchkey's own browser (FR-439) copies only while locked too. Not chosen: a
setting, or Claude choosing the browser per page (the maintainer's rule decides from the sign-in itself).

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/BrowserActionTests.swift`
- `macos/Tests/BrowserTabTests.swift`
- `macos/Tests/SignInRoutingTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
