# Spec 013: Signing in by itself — WHAT and WHY

Status: Approved and built (Toni, 2026-11-20: "do the whole thing"); plan `plan.md`, tasks
`tasks.md`, tools `contracts/login-tools.md`. Two tools, `logins_find` and `logins_sign_in`
(Toni, 2026-11-21, after the MCP research in `research.md`).
Scope: Latchkey signs in to sites by itself with copies of the Owner's existing passwords and
verification codes, which the Owner hands over from Apple's Passwords app. Latchkey, never
Claude, fills in the secret; Claude never sees it.
Out of scope: registering passkeys of Latchkey's own on the Owner's accounts (Toni, 2026-11-20:
"that'll mess up everything"); a live link to Apple's Passwords (none exists: `research.md`);
other password managers; creating accounts or changing passwords.
Later: passkeys. Apple hands passkeys only to apps signed through the paid Apple Developer
Program, through its export to another app; Latchkey uses Passwords' file export for now (Toni,
2026-11-20: "CSV file for now"), which never contains passkeys. FR-1330 to FR-1339 are kept for
that step and are not built now.

Research, with a test run on Toni's Mac: `research.md`.

## Problem

While the Mac is locked, Claude's pages open in Latchkey's own browser with copies of Safari's
cookies (spec 005 FR-457). When a site's sign-in has expired in Safari, or the site signs
Latchkey's copy out, Claude reaches a sign-in page and can go no further: the Owner is away, and
nothing on the Mac can sign in for them. Apple's Passwords app can't be scripted and has no
interface another app can read (`research.md`), so the only way in is a copy the Owner hands over.

## User stories

### US1 (P1): Hand over my sign-ins
1. Given I'm setting up Latchkey, when I reach the sign-ins step and click Export, then
   Latchkey opens Passwords and exports my passwords itself; I only approve with Touch ID.
   Latchkey takes them in, deletes the file at once, closes Passwords, and says how many
   sign-ins it now holds (Toni, 2026-11-20: "latchkey needs to export the CSV itself
   automatically"; "One touch, when you click").
2. Given a week has passed since my last export, then Latchkey shows a notification (never a
   window in front) inviting me to export again; clicking it does the same one-touch export.
3. Given I export again, then Latchkey's copies are replaced by the new file's: changed passwords
   change, and sign-ins I deleted in Passwords are gone from Latchkey too.

### US2 (P1): Claude gets past a sign-in page while I'm away
1. Given Claude reaches a site's sign-in page and Latchkey holds a sign-in for that site, when
   Claude asks Latchkey to sign in, then Latchkey fills in and sends the sign-in itself and
   Claude goes on from the signed-in page.
2. Given the site then asks for a verification code that Latchkey holds, then Latchkey fills in
   the current code too.
3. Given Latchkey holds no sign-in for the site, then Claude is told so at once, in plain words.
4. This works in Latchkey's own browser (Mac locked, or a site I'm not signed in to) and in
   Claude's own Safari tabs (Mac unlocked).

### US3 (P1): Claude knows what it can sign in to, and never holds a secret
1. Given Claude asks, then it gets the list of sites Latchkey can sign in to, with the user name
   for each, and never a password or code.
2. Claude never sees a password or a code: not in a page it reads, not in an answer, not in
   Latchkey's log or traces.

### US4 (P1): I decide
1. Sign-in is a setting of its own in Latchkey, on by default; given I turn it Off, then no
   sign-in action, list, or mention exists for Claude (Constitution III).
2. Given I choose to remove Latchkey's copies, then they are gone from the Mac at once, and
   uninstalling Latchkey removes them too (Constitution IV).

## Requirements

### Taking the sign-ins in

- **FR-1300** Latchkey shall take sign-ins only from Apple's Passwords app's export of all
  passwords to a file, approved by the Owner, never from any other source or program.
- **FR-1301** When the Owner clicks Export (in setup, in Latchkey's menu, or on the reminder of
  FR-1304), Latchkey shall open Passwords and run its export itself (File → Export All Passwords
  to File, the confirmation, the save), so the Owner only approves with Touch ID or their Mac
  password. Latchkey shall save the file in a folder of its own that isn't synced, read it,
  delete it at once, close Passwords if Latchkey opened it, and say how many sign-ins (and how
  many with verification codes) it now holds. A file that can't be read is deleted too, and the
  Owner is told why it failed. While it runs, Latchkey's menu and Settings show the step it is
  on; when it ends, how it ended comes as a notification too, so the Owner knows it is done
  without opening Latchkey (Toni, 2026-11-21: "why is there no progress indicator? … How do I
  know it's complete?"). Passwords comes to the front for this, because the Owner clicked
  (Toni, 2026-11-20: "One touch, when you click"; Passwords can't be scripted and asks for the
  Owner's approval on every export, `research.md`, so no export without the Owner exists).
- **FR-1307** No copy of the export shall be left anywhere else. When an export stops, Latchkey
  shall cancel the save panel and check that it closed, and if it didn't, tell the Owner to close
  it with Cancel. For 10 minutes after a stop, a file with that export's name that turns up where
  a save panel may put it (the home folder, Desktop, Documents, Downloads, iCloud Drive, the
  cloud folders of other providers) shall be overwritten and deleted, and the Owner told (Toni,
  2026-11-21: "does it clean up after unsuccessful exports, too, or is a stale file with all my
  passwords left in my Downloads folder?").
- **FR-1306** Export shall work only while the Mac is unlocked, and only after the Owner clicked;
  Latchkey shall never start it by itself. When the Owner doesn't approve within 2 minutes, or
  Passwords' window isn't what Latchkey expects, Latchkey shall stop, leave Passwords open as it
  is, keep the old copies, and say what happened. Without the Accessibility permission (which
  Latchkey asks for at setup), Latchkey shall show the steps to export by hand and pick up the
  file the Owner saves.
- **FR-1302** The setup step for sign-ins may be skipped; a skipped step shall not count as
  missing setup (it doesn't open the setup window again, spec 001 FR-205).
- **FR-1303** Each import shall replace every copy Latchkey held with the new file's contents, all
  or nothing: when the new file can't be read in full, the old copies stay.
- **FR-1304** When 7 days have passed since the last import (or since setup, when there was none),
  Latchkey shall post one notification inviting the Owner to export again, and again every 7
  days until they do or turn the reminder off. The notification shall never bring a window to the
  front (Constitution IV); clicking it starts the export of FR-1301 (Toni, 2026-11-20: "can't that
  be automated without front window": it can't, Passwords needs the Owner's Touch ID for every
  export and can't be scripted, so a notification is the least intrusive reminder).
- **FR-1305** The Owner shall be able to remove every copy from Latchkey's menu, at once; when the
  Owner uninstalls Latchkey, the copies shall be removed with it.

### Keeping them

- **FR-1310** Latchkey shall keep its copies only on this Mac, in its Keychain, readable while the
  Mac is locked, never synced to iCloud, never sent to the relay, and never written to a log,
  trace, or answer.
- **FR-1311** A password or code Latchkey filled in shall be hidden from Claude when it reads the
  page, as every password and code field is (spec 005 FR-410).

### Signing in

- **FR-1320** While Sign-in is On, Claude shall be able to ask Latchkey to sign in on a page of its
  own (in Latchkey's own browser or in one of Claude's Safari tabs), optionally naming which user
  name when Latchkey holds more than one for the site (Toni, 2026-11-20: "When Claude asks").
  Latchkey shall never fill a sign-in Claude didn't ask for, and never in the Owner's own Safari
  tabs.
- **FR-1321** Latchkey shall fill a sign-in only into a page at an `https` address whose host is the
  site the sign-in was saved for or one of its subdomains (a sign-in saved for `amazon.com` fills on
  `www.amazon.com`), into the page itself and never into a frame from another site (Toni,
  2026-11-20: "Its site and subdomains"). A site that is itself a public suffix (a shared host
  such as `herokuapp.com`, by the Public Suffix List), or an international or malformed name,
  fills on its own host only.
- **FR-1328** Which site a page is on shall be decided from the browser's own record of its
  address, never from anything the page's scripts report, and the page shall be checked again
  just before each fill (security review, 2026-11-21).
- **FR-1322** When the page asks for a user name and password (on one page or one after the other),
  Latchkey shall fill them in and send the form; when the page asks for a verification code and the
  sign-in has one, Latchkey shall fill in the current code and send it.
- **FR-1323** The answer shall say what happened in plain words: signed in, which step the page now
  asks for (a code Latchkey doesn't hold, a new-device check, a captcha), or what the page said
  when it refused; it shall never contain the secret.
- **FR-1324** When a sign-in fails, Latchkey shall allow Claude one more try of it; after the second
  failure, Latchkey shall refuse that sign-in until the next import, saying why (Toni, 2026-11-20:
  "Try once more"). A code refused once is never sent again; the retry waits for the next code.
- **FR-1325** When Latchkey holds no sign-in for the page's site, the answer shall say so at once.
- **FR-1326** While Sign-in is On, Claude shall be able to list the sites Latchkey can sign in to,
  with the user name for each and whether it has a verification code, never a password or code.
- **FR-1327** Every sign-in Latchkey makes shall go into Latchkey's activity log: the site, the user
  name, the browser, and the outcome, never the secret.

### Latchkey's own sign-ins, so Safari stays signed in (Toni, 2026-11-21)

Toni, 2026-11-21: "can it not sync cookies to its own browser for the websites it has login for,
so it doesn't log my real browser out?" Then, asked: "Own sign-in, cookies as fallback", "Keep,
protected", "Latchkey's own browser" (also while unlocked). A copy of Safari's cookies that a site
renews signs Safari out (spec 005 FR-456, Target); a session of Latchkey's own doesn't touch
Safari's.

- **FR-1350** While Sign-in is On, Claude's pages in Latchkey's own browser shall take none of the
  Owner's Safari cookies for a site Latchkey holds a saved sign-in for (by FR-1321's matching),
  locked or unlocked: neither the site's own nor a cookie of a wider domain that would reach it.
  Claude signs in there with Latchkey's own sign-in (FR-1320). Amends spec 005 FR-441, FR-442,
  FR-457 for those sites.
- **FR-1351** While the Mac is unlocked, a page of such a site shall open in Latchkey's own
  browser, not in a Safari tab of Claude's. Amends spec 005 FR-455 and FR-459 for those sites.
- **FR-1352** When Latchkey's own sign-in can't finish on such a site (the site asks for a code
  Latchkey doesn't hold, shows a check it can't answer, or refuses the password), Latchkey shall
  use the Owner's Safari sign-in for that site as spec 005 does: while the Mac is locked, take
  Safari's cookies for the site and load the page again; while unlocked, move the page into a
  Safari tab of Claude's. The answer says that Latchkey's own sign-in couldn't finish, why, and
  that the Owner's Safari sign-in is used instead (which may sign Safari out on some sites, as
  before). The site stays on Safari's sign-in until the Owner's next export or Remove All. A site
  here is every saved sign-in registered under the same name (amazon.com and
  na.account.amazon.com are one; live check 2026-11-21: Amazon's sign-in is in cookies for all of
  amazon.com, which the second saved sign-in still held back), and what Latchkey's own try left
  in its browser for it is dropped before the copy.
- **FR-1353** The cookies a site sets in Latchkey's own browser for a site of FR-1350 (its own
  sign-in) shall be kept on this Mac across Latchkey's restarts and updates, in Latchkey's
  Keychain as the sign-ins are (FR-1310), never readable by Claude's command line or Files tools,
  never synced or sent anywhere. Copies of Safari's cookies are never kept (spec 005 FR-421). A
  kept cookie goes when it expires; one with no expiry after 14 days.
- **FR-1354** Unlocking the Mac (spec 005 FR-458) shall drop only the copies of Safari's cookies,
  never Latchkey's own sign-ins. Remove All and uninstalling (FR-1305) shall remove the kept
  sign-ins too. While Sign-in is Off, they are neither used nor kept up to date, and Claude's
  pages behave as spec 005 says.
- **FR-1355** Every answer from Latchkey's own browser for a page of such a site shall say that
  Latchkey signs in to that site itself, with logins_sign_in when the page asks to sign in, not
  that the page is "without the owner's sign-ins" (live check 2026-11-21: that read as a
  contradiction next to "Signed in").

### Codes texted to the Owner (Toni, 2026-11-21)

Toni, 2026-11-21, after a live check sent him two Amazon code texts Latchkey couldn't use:
"Ensure you can use OTP. Mark them read and archive/delete after use"; then, asked: "Delete at
once when unlocked" and "Any new code text".

- **FR-1360** When a site asks for a verification code during Latchkey's own sign-in and Latchkey
  holds no code generator for it, Latchkey shall take the code from the newest text in Messages
  on this Mac that arrived after that sign-in began, isn't from the Owner, and holds a code (4 to
  8 digits), whoever sent it, and fill it in itself as FR-1322 does; Claude never sees it. Each
  text is used once. While Messages is Off in Latchkey's settings, or Latchkey can't read
  Messages, no text is used.
- **FR-1361** One sign-in call waits for that text for as long as the call's time allows; when the
  text hasn't come by then, the answer says the site texted a code that hasn't arrived and to call
  again on the same page, and the next call takes it. A text is waited for up to 2 minutes from
  the site's request; after that, the sign-in counts as needing a code Latchkey doesn't hold
  (FR-1352's fallback follows).
- **FR-1362** After Latchkey used a code text, it shall delete that text in Messages (from all the
  Owner's devices, kept in Recently Deleted as Messages does), through Messages' own window in
  the background, without bringing Messages forward: at once while the Mac is unlocked, else as
  soon as it is unlocked, also after a restart in between. Only that one message, never the
  conversation. This is an exception Toni chose to never disturbing the user (Constitution IV):
  Messages' window may show that conversation. When the window can't do it (another language,
  the message not shown, Accessibility not allowed), the text stays, and Latchkey's log says why.
- **FR-1363** Latchkey's log records each code text used and deleted (when, the site, never the
  code or the text).

### Passkeys (later, not built now)

- **FR-1330** When Latchkey is signed through the paid Apple Developer Program, Latchkey shall take
  passwords, passkeys, and verification codes through Apple's export to another app, approved by
  the Owner with Touch ID, with no file in between.
- **FR-1331** Latchkey shall then answer a site's passkey request in its own browser with the
  Owner's exported passkey, when Claude asked to sign in, under the rules of FR-1321 to FR-1327.

### The setting

- **FR-1340** Sign-in shall be a capability of its own in Latchkey's settings, On or Off, On by
  default (Toni, 2026-11-20). While it is Off, no sign-in action or list exists for Claude and no
  answer mentions it (Constitution III); the copies stay until the Owner removes them.

## Success criteria

- With the Mac locked and the lid closed, Claude signs in to a site whose Safari sign-in has
  expired, with no help from the Owner, and finishes the task.
- No secret appears in anything Claude, the relay, the log, or the traces receive (a test searches
  them for every imported secret).
- The exported file is gone within seconds of appearing.

## Edge cases

- A site that sends a code by text or email after the password: Latchkey says so; Claude may read
  the text with Messages, if that is on.
- A site that asks for a new-device check, or a captcha: Latchkey stops and says so.
- A site where the code goes after the password in the same field (Apple's list,
  `research.md`): Latchkey fills the password and code together.
- A sign-in form inside a frame from another site: not filled (FR-1321).
- A lookalike address (`amaz0n.com`): no match, nothing filled.
- Several sign-ins for one site: Claude names the user name; without one, Latchkey asks Claude to
  choose from the list.
- The exported file: saved in Latchkey's own folder, never iCloud Drive; that folder is left out
  of Time Machine; the file lives for seconds.
- The Owner is using Passwords when they click Export: Latchkey uses its open window and leaves
  it open afterwards.
