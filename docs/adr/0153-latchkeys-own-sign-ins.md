# 0153. Latchkey's own sign-ins (FR-1350, FR-1351, FR-1353 to FR-1355, FR-1374)

- Status: accepted
- Date: 2026-11-22
- Alias: plan 013 D10 (`specs/013-sign-in/plan.md`, "D10. Latchkey's own sign-ins (FR-1350, FR-1351, FR-1353 to FR-1355, FR-1374)")

## Context and problem

Decision D10 of spec 013's plan (Signing in); requirements in
[requirements/sign-in.md](../requirements/sign-in.md). Requirement IDs it cites: FR-1350, FR-1351, FR-1353, FR-1355, FR-1374, FR-459, FR-421, FR-1354.
The design it belongs to: [design/sign-in.md](../design/sign-in.md).

## Decision


(2026-11-22: FR-1352's fallback is withdrawn; there is no fallback list. Claude moves a page into
Safari with sign_in_again while unlocked, FR-1374; locked, the answer says Safari waits for the
unlock. Kept items written with the old fallback keys still read: Codable leaves them out.)

`OwnSessions` (App/SignIn) knows the own sites: those a held sign-in fills on (`SiteMatch.fills`),
minus the sites that fell back to Safari (FR-1352), while Sign-in is On. It answers two questions
for the browser: is this host an own site, and does a cookie of this domain reach one (the
domain is an own site, under one, or a wider domain of one, as `LockedBrowser.covers` decides).
- FR-1350: `LockedBrowser` asks before every copy of Safari's cookies: no copy for an own host,
  and from a copy for any other host the cookies that would reach an own site are left out.
- FR-1351: `OwnPages.inSafari` is false for an own host; `browser_sign_in_again` on an own site's
  page answers that Latchkey signs in there itself (logins_sign_in), unless it fell back.
- FR-1352: when `logins_sign_in` in Latchkey's own browser ends with a code it doesn't hold, a
  check, or a refusal, the site is marked fallen back (with the import date it applies to, so
  the next export clears it), and with it every held site of the same registered name
  (`PublicSuffix.registrable`), then: locked, the cookies the browser holds for those sites go,
  Safari's are copied, and the address the page had when the sign-in began opens again (a
  fresh load: a reload resends a code step);
  unlocked, the page moves into a Safari tab of Claude's (FR-459's way). The answer says so.
- FR-1353: the store's changes (`CookieWatch` already observes it) are looked at 1 s after they
  settle; the cookies that reach an own site are written to a Keychain item of their own
  (account "sign-in sessions": JSON of name, value, domain, path, expiry, secure, HttpOnly,
  SameSite, and when it was kept), when they changed. A new store (`OwnPages.make`) gets them
  back before its first page. Expired ones, and ones with no expiry kept over 14 days, are
  dropped when read. Options weighed: a persistent `WKWebsiteDataStore` (WebKit's own files under
  ~/Library/WebKit, readable by Claude's command line unless fenced, and it would also keep the
  copies of Safari's cookies, which FR-421 forbids) vs Latchkey's own Keychain item with only
  its own sign-ins (encrypted, readable only by Latchkey, as the sign-ins are); the Keychain item
  chosen.
- FR-1354: `forgetCopiesIfUnlocked` keeps the own sign-ins: it saves them, drops every cookie,
  and sets them back. Remove All and uninstall delete the item. While Sign-in is Off,
  `OwnSessions` has no own sites, so nothing changes from spec 005.
- FR-1355: `BrowserCapability.ownBrowser` names the case: "with Latchkey's own sign-in for
  <site> (if the page asks to sign in, logins_sign_in signs in)".

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/OwnSessionsTests.swift`
- `macos/Tests/SignInFillTests.swift`
- `macos/Tests/SignInRoutingTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
