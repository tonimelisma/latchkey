# 0066. While the Mac is locked: a browser of Latchkey's own (FR-420 to FR-422, decided 2026-11-02)

- Status: accepted
- Date: 2026-11-02
- Alias: plan 005 D7 (`specs/005-browser/plan.md`, "D7. While the Mac is locked: a browser of Latchkey's own (FR-420 to FR-422, decided 2026-11-02)")

## Context and problem

Decision D7 of spec 005's plan (Browser control); requirements in
[requirements/browser.md](../requirements/browser.md). Requirement IDs it cites: FR-420, FR-422, FR-661, FR-441, FR-442.
The design it belongs to: [design/browser.md](../design/browser.md).

## Decision


Seen live 2026-11-01: with the Mac locked, Safari answers the first script and then no more (every
script times out). Latchkey never gets around the lock (spec 001 FR-661). Tried live while locked
on 2026-11-02: an off-screen `WKWebView` in a process of its own loaded a page, ran its scripts,
went to an address and back, and drew a full picture of the page (`takeSnapshot`); a link
clicked by a script didn't navigate there, so the click follows the link's address itself.
Options the maintainer was shown: nothing while locked; the built-in browser for public pages; the same
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

Since 2026-11-14 (FR-441, FR-442; the maintainer): the copy is no longer made once. Seen 2026-11-14: Amazon
answered Claude signed out, with an empty cart, in this browser, while Safari was still signed
in and Safari's file held Amazon's sign-in cookies with 345 days left. `takeSafarisCookies`
reads Safari's file again before each page Claude opens (`open`), and when Claude asks
(`browser_read sign_in_again`, which then loads the page again): it asks the store for what it
holds (one call) and sets only Safari's cookies that are missing or differ in value, so a
second copy costs a file read and a handful of writes, not 3,000 (a store just made is filled
without asking: WebKit doesn't answer what a store holds before it is in use, seen live
2026-11-14, locked, when the first page never came; and when it gives no answer in 2 s, every
cookie is set again). Safari's value wins for a
cookie both hold; a cookie only this browser holds stays (a site's own step-by-step state).
It isn't done on click, type, or back: those are steps inside one visit, where swapping a
cookie under the page could break a form's own token; the page Claude gets there can be
loaded again with `sign_in_again`. Nothing goes back to Safari: its file can't be written
safely while Safari runs. Known limits: Safari writes its file a little after a change, so the
copy can be moments behind; a site that refuses this browser itself stays signed out however
fresh the copy.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/BrowserActionTests.swift`
- `macos/Tests/BrowserOwnerTabTests.swift`
- `macos/Tests/LockedBrowserTests.swift`
- `macos/Tests/SafariCookiesTests.swift`
- `macos/Tests/SignInRoutingTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
