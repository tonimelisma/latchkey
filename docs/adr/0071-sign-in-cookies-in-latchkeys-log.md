# 0071. Sign-in cookies in Latchkey's log (FR-453, FR-454, 2026-11-15)

- Status: accepted
- Date: 2026-11-15
- Alias: plan 005 D12 (`specs/005-browser/plan.md`, "D12. Sign-in cookies in Latchkey's log (FR-453, FR-454, 2026-11-15)")

## Context and problem

Decision D12 of spec 005's plan (Browser control); requirements in
[requirements/browser.md](../requirements/browser.md). Requirement IDs it cites: FR-453, FR-454.
The design it belongs to: [design/browser.md](../design/browser.md).

## Decision


`CookieWatch` (App/Browser/CookieWatch.swift) is made with the cookie store Claude's pages share
(`OwnPages`) and dropped with it. `LockedBrowser.takeSafarisCookies` hands it the cookies each
copy set and the age of Safari's cookie file (`SafariCookies.fileAge`, its modification date);
it writes one line. As a `WKHTTPCookieStoreObserver` it looks at the store 0.3 s after a change
(changes made together are one look), compares the sign-in cookies with those last seen, and
writes one line per site. Lines go to the new event category `browser`, so they are kept in the
activity log, shown in the Activity window ("Browser Sign-Ins"), and returned by `latchkey_log`
(category `browser`). A sign-in cookie is one that is HttpOnly or named for a token (research,
"Sign-outs from Safari"). Site names and cookie names go to macOS's log in public; values never
leave the store.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/CookieWatchTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
