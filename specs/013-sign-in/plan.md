# Plan 013: Signing in by itself — HOW

Spec: `spec.md`. Research: `research.md`. Approved to build by Toni, 2026-11-20 ("do the whole
thing"). Everything is in the Mac app; the relay and the Linux program don't change (tools are
defined on the Mac and pass through the relay as they are).

## D1. Where the copies live (FR-1310, FR-1305)

One generic-password item in the login keychain, account `sign-ins`, under the app's own Keychain
service (`AppIdentity`), through the existing `Keychain` helper: accessible after first unlock,
this device only (readable while locked, as the pairing is; `research.md`), trusting only this
app. Its data is JSON: the import's date and the list of `SavedSignIn` (title, site, user name,
password, `otpauth` address). Tests use a memory vault (the `PairingVault` protocol;
`KeychainVault` writes nothing under XCTest). Removing (menu, uninstall watcher in
`Installation.swift`) deletes the item. Options weighed: one item per sign-in (hundreds of
Keychain items, slower list, partial imports possible) vs one item (all or nothing for free,
FR-1303); one item chosen.

## D2. Taking a file in (FR-1300, FR-1301, FR-1303)

A folder of Latchkey's own, `~/Library/Application Support/<app>/Sign-in Import` (0700, left out
of Time Machine with `isExcludedFromBackup`, never in iCloud Drive), watched while the app runs
(a file-system event source plus a check every 2 s). A `.csv` that appears there is read once it
stops growing, parsed (`PasswordsCSV`), stored (replacing everything, only when the whole file
parsed), overwritten with zeros, and deleted; the Owner gets a notification with the count. A
file that isn't Passwords' export is deleted too, and the notification says why. The folder is
where the one-touch export (D3) saves, and where the hand steps tell the Owner to save. Options
weighed: watching Downloads (needs that folder's permission, and the file could sync) vs a
private folder; the private folder chosen.

## D3. The one-touch export (FR-1301, FR-1306)

`PasswordsExport` drives Passwords through Accessibility (the permission setup already asks for):
open Passwords (`NSWorkspace`, it comes to the front because the Owner clicked); wait up to 2
minutes for File → Export All Passwords to File… to be enabled (it is while Passwords is unlocked:
the Owner's Touch ID); press it; press the confirmation's Export button; in the save panel, set
a unique file name, open Go to Folder (Command-Shift-G), put the import folder's path in its
field, Return, and press Save; then D2 takes the file. Each step looks for its element by role
and title for up to 10 s; anything unexpected stops the export, cancels the panel, leaves
Passwords as it is, and says which step. Passwords is quit afterwards only if Latchkey started it.
Each step's name shows in the menu and Settings while it runs; a stop also comes as a
notification, and a finished import sends its own (D2).

Found on the first real run (2026-11-21), and how it works since:
- Latchkey looks only in Passwords' dialogs (the sheets on its windows, and windows that aren't
  standard ones), never in the main window: with 1,045 passwords that window is about 4,500
  Accessibility elements, and one look through it took 85 s. A sheet is about 14 elements and
  0.07 s. Each Accessibility call has a 1 s limit.
- The save panel runs in a process of its own (`openAndSavePanelService`), so keys sent to
  Passwords' process alone (`CGEvent.postToPid`) never reach it: Go to Folder didn't open and the
  export stopped. The two key presses (Command-Shift-G, Return) are posted as the keyboard posts
  them, and only while Passwords is in front (brought back once if not); otherwise the export
  stops and cancels the panel. Tried on TextEdit's panel, the same one: it opens and saves where
  told.
- No file left behind (FR-1307): every stop presses the panel's Cancel and checks the panel
  closed (else the Owner is told to close it with Cancel); for 10 minutes after a stop, every
  3 s, `PasswordsExport.sweep` wipes a file of the export's unique name in the home folder,
  Desktop, Documents, Downloads and iCloud Drive (two levels down) and `Library/CloudStorage`
  (three), and a notification says so.
- A full path in the name field doesn't work: AppKit turns each `/` into `:` and saves in the
  panel's current folder (tried: a file in Downloads).
Only while unlocked, only from a click (menu, Settings, setup, the reminder). Without Accessibility
the hand steps show instead.

## D4. The weekly reminder (FR-1304)

At start and every hour: when the reminder is on, the last import (or the first start of this
version, when there was none) is 7 days old or more, and no reminder went out in the last 7 days,
post one notification (category `signins.export`). A click starts D3. The setting and the dates
are in user defaults; never a window (Constitution IV).

## D5. The tools (FR-1320, FR-1326, FR-1340; contract `contracts/login-tools.md`)

A capability `logins` ("Sign-in"), levels Off and On (On by default), with a read tool
`logins_find` and a write tool `logins_sign_in` (Toni, 2026-11-21: "Two: logins_find +
logins_sign_in", after the MCP research: a read-only tool is approved without asking in Claude's
apps). Off: neither exists (Constitution III).

## D6. Filling a page (FR-1321, FR-1322, FR-1311)

`logins_sign_in` takes `page` (Claude's page, as the browser tools name it) and an optional
`user`. It works only in Claude's own pages: Latchkey's own browser, or a Safari tab of Claude's
(spec 005 FR-455); never the Owner's tabs. Steps, at most four per call:

1. Read the page's address; pick the sign-ins whose site fills there (`SiteMatch`). None: say so
   (FR-1325). Several user names and none given: list them.
2. Run the step script (`PageScripts.signInStep`) in the page's main frame only. It checks the
   page is https on that site itself (so a page that moved meanwhile gets nothing), finds the
   visible fields (password, verification code, or a user name alone, as on a two-page sign-in),
   fills them with the field's own value setter and input events, and sends the form (its submit
   button, else Enter).
3. Wait for the page to settle (the browsers' own action wait), look again (`signInState`), and
   go on: a code field and a code held fills the code; a password field again after the password
   was sent is a failure; nothing to fill is done.
4. Last, clear every password field and any code field Latchkey filled that is still on the page
   (`clearSignIn`), so no script of Claude's can read them; page reads already hide such fields
   (spec 005 FR-410).

Secrets reach the page only inside the script: in Latchkey's own browser through WebKit
directly; in Safari always through the 0600 script file in a 0700 folder, removed right after,
never as an `osascript` argument (which other programs can see). Options weighed: typing with
keystrokes (needs the front window, Constitution IV) vs the value setter; the value setter
chosen, as the browser tools' own `type` does.

## D7. Outcome and retries (FR-1323, FR-1324, FR-1327)

The answer names the outcome in words (signed in; asks for a code Latchkey doesn't hold; a
captcha or new-device check; the site refused, with the page's words), then the page as the
browser tools show it. A refusal counts against that sign-in (site and user name, in memory); the
second refusal blocks it until the next import. A code is never sent twice in one time step.
Every sign-in goes into the activity log (site, user name, browser, outcome).

## D8. Where the Owner sees it (FR-1301, FR-1302, FR-1305)

Settings → What Claude Can Do lists Sign-in with the other capabilities and, while it is on, a
section with how many sign-ins Latchkey holds and from when, Export from Passwords…, Remove All,
and the reminder switch. The menu has Export Passwords to Latchkey…. Setup gets a sixth step,
"Hand over your sign-ins (optional)", which never counts as missing (FR-1302).

## D10. Latchkey's own sign-ins (FR-1350 to FR-1355)

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

## D11. Codes texted to the Owner (FR-1360 to FR-1363)

`TextedCodes` (App/SignIn): when `SignInFlow` reaches a code step and the sign-in has no code
generator, it asks for a texted code. Messages' database (its own read-only connection, as
`messages_find` reads) is looked at every second for texts not from the Owner that arrived
since the site's request (the first time it asked, kept for 2 minutes across calls), newest
first; the first unused one holding a code is taken. A code is a run of 4 to 8 digits standing
alone next to a word like "code", "OTP", "verification" (also Finnish and other languages'); a
text with numbers but no such word is no code text (security review 2026-11-21). A text is
queued for deleting only after the sign-in with its code succeeded, and deleted only while
Messages is Read & write. Each text id is used once (in
memory). One call waits up to 45 s (the relay allows 60 s); with no text by then the answer
asks for another call, and after 2 minutes the sign-in counts as needing a code (D10's fallback).
No text is used while Messages is Off.

After use, the text's id joins a list kept in user defaults (an id, no text), and the list is
worked through at once while the Mac is unlocked, else on the unlock notification and at start:
`CodeTextWindow.delete` opens `sms://open?message-guid=` without activating Messages, requires the
window's title to name that conversation's people (a short code must match whole), finds the one
message on the other side with that text, performs Messages' own "Delete…", answers the sheet,
and waits until Messages' database no longer lists the message. Recovered from spec 002's
withdrawn window actions (commit 6b9beb3), delete only. Each id is tried once; a failure is
logged and the text stays.

## D12. Codes emailed to the Owner (FR-1364 to FR-1367)

`logins_sign_in` takes `code` (what Claude read in the Owner's email with its own tool) and
`no_email_access` (Claude has no email tool). Without either, a call waits 20 s for a text, then
asks Claude whether it can read the Owner's email: with a tool, Claude passes `code`; without,
`no_email_access`, and `MailCodes` starts Mail hidden (`NSWorkspace`, `activates` false, `hides`
true) and reads its index (`~/Library/Mail/V<n>/MailData/Envelope Index`: emails received since
the request, not in sent, draft, deleted, or trash mailboxes) and each email's own file
(`<account>/<mailbox>.mbox/<store>/Data/<id/1000's digits reversed>/Messages/<id>.emlx`; its
plain-text parts, else its HTML without head, styles, scripts, and tags; base64 and
quoted-printable decoded), because Mail's summary comes hours late (1 of 35 emails of the last
12 hours had one, 2026-11-21). Options weighed: Mail's scripting to read (needs Mail running and
froze behind the lock) vs its files (Full Disk Access, which Latchkey has, works locked); the
files chosen. After a sign-in that worked, the email (by Mail's id, account id, and mailbox name)
joins D11's list and is marked read and moved to the account's "Archive", "All Mail", or
"[Gmail]/All Mail" mailbox by an AppleScript run through `OSAScriptRunner` (which never shows a
permission question), while unlocked. For a code Claude passed, Mail's index is searched (never
started) for an email of the last 10 minutes holding that exact code, archived the same way;
without one, the answer asks Claude to archive it with its tool.

## D9. Tests and checks

- Unit: `SignInDataTests` (CSV, codes with RFC 6238's vectors, site matching), `SignInStoreTests`
  (replace all or nothing, failures, memory vault), `SignInPageTests` (the real WebKit view with
  fixture pages at an https address: one-page and two-page forms, a code step, a frame from
  another site, a page of another site, a refused password, fields cleared, no secret in any
  answer), `SignInToolsTests` (the tools: Off means gone, list, no sign-in, several users,
  second failure blocks), `PublicToolsTests` (27 tools), `ReadmeTests`.
- Export: the first real export is Toni's click on Export Passwords to Latchkey… in the menu
  (his Touch ID); Claude then checks the log shows the file taken in and deleted.
- Live (screen-state cases, group `logins`): with a test sign-in for the public test site
  the-internet.herokuapp.com dropped into the import folder (only while Latchkey holds no
  sign-ins of the Owner's, so nothing of his is replaced; removed in teardown), a fresh Claude
  lists the site, signs in, and the traces are searched for the password.

## Constitution check

- I (no inbound): unchanged. II (fail fast): every step has a limit (10 s per element, 2 minutes
  for Touch ID, the tools' 30 s). III (off is gone): the capability's tools vanish at Off. IV
  (good citizen, never disturb): Passwords comes forward only because the Owner clicked; the
  reminder is a notification; filling uses no keystrokes or pointer; uninstalling removes the
  copies. V (self-hostable): nothing on the relay. VI (store the minimum): the copies stay on the
  Mac; traces never hold a secret (tool arguments and answers don't). VII (test-first): tests
  above, written first. VIII (simplicity): one item, one folder, no new program or package. IX:
  no new dependencies.
