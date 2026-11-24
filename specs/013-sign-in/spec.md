# Spec 013: Signing in by itself — WHAT and WHY

Status: Approved and built (Toni, 2026-11-20: "do the whole thing"); plan `plan.md`, tasks
`tasks.md`, tools `contracts/login-tools.md`. Two tools, `logins_find` and `logins_fill` (was
`logins_sign_in` until 2026-11-22; Toni, 2026-11-21, after the MCP research in `research.md`).
Scope: Claude signs in to sites with copies of the Owner's existing passwords and verification
codes, which the Owner hands over from Apple's Passwords app. Claude reads each page and decides
what to do; Latchkey types the saved secret into the field Claude names and presses the button
Claude names (FR-1371, Constitution X), so Claude never sees a password or a code from
Passwords. Codes the site texts or emails, Claude reads itself (FR-1375).
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
1. Given Claude reaches a site's sign-in page and Latchkey holds a sign-in for that site, then
   Claude has Latchkey type the user name and the password into the fields it names and press the
   button it names, reads the page that follows, and goes on (FR-1371).
2. Given the site then asks for a verification code, then Claude has Latchkey type the current
   code from Passwords, or reads a texted or emailed code itself and passes it (FR-1375).
3. Given Latchkey holds no sign-in for the site, then Claude is told so at once, in plain words.
4. This works in Latchkey's own browser (Mac locked, or a site I'm not signed in to) and in
   Claude's own Safari tabs (Mac unlocked).

### US3 (P1): Claude knows what it can sign in to, and never holds a secret
1. Given Claude asks, then it gets the list of sites Latchkey can sign in to, with the user name
   for each, and never a password or code.
2. Claude never sees a password or a code from Passwords: not in a page it reads, not in an
   answer, not in Latchkey's log or traces. (A code the site texts or emails, Claude reads itself;
   Toni, 2026-11-22.)

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

- **FR-1320** While Sign-in is On, Claude shall be able to ask Latchkey to type a saved user name,
  password, or code on a page of its own (in Latchkey's own browser or in one of Claude's Safari
  tabs; FR-1371), optionally naming which user name when Latchkey holds more than one for the
  site (Toni, 2026-11-20: "When Claude asks"). Latchkey shall never fill anything Claude didn't
  ask for, and never in the Owner's own Safari tabs.
- **FR-1321** Latchkey shall fill a sign-in only into a page at an `https` address whose host is the
  site the sign-in was saved for or one of its subdomains (a sign-in saved for `amazon.com` fills on
  `www.amazon.com`), into the page itself and never into a frame from another site (Toni,
  2026-11-20: "Its site and subdomains"). A site that is itself a public suffix (a shared host
  such as `herokuapp.com`, by the Public Suffix List), or an international or malformed name,
  fills on its own host only. "Its site" is the registered site, as Passwords and Safari fill: a
  sign-in saved at `access.bannerlife.com` fills on `login.bannerlife.com` (live test 2026-11-21:
  Banner Life's sign-in page is on a sibling host); the one saved for the page's own host is
  used first. A shared host's customers are each their own registered site, and an IP address
  fills only on itself.
- **FR-1328** Which site a page is on shall be decided from the browser's own record of its
  address, never from anything the page's scripts report, and the page shall be checked again
  just before each fill (security review, 2026-11-21).
- **FR-1322** (Withdrawn 2026-11-22: sign-in is Claude's now, with Latchkey typing only what Claude names (FR-1371); Toni: "Shouldn't the code just provide what's happening in the browser and the agent makes the presumptions?" Was: When the page asks for a user name and password (on one page or one after the other),
  Latchkey shall fill them in and send the form; when the page asks for a verification code and the
  sign-in has one, Latchkey shall fill in the current code and send it.)
- **FR-1323** (Withdrawn 2026-11-22: sign-in is Claude's now, with Latchkey typing only what Claude names (FR-1371); Toni: "Shouldn't the code just provide what's happening in the browser and the agent makes the presumptions?" Was: The answer shall say what happened in plain words: signed in, which step the page now
  asks for (a code Latchkey doesn't hold, a new-device check, a captcha), or what the page said
  when it refused; it shall never contain the secret.)
- **FR-1324** (Withdrawn 2026-11-22: no cap on fills (Toni: "No cap"); Claude reads whether the site took the password. Was: When a sign-in fails, Latchkey shall allow Claude one more try of it; after the second
  failure, Latchkey shall refuse that sign-in until the next import, saying why (Toni, 2026-11-20:
  "Try once more"). A code refused once is never sent again; the retry waits for the next code.)
- **FR-1375** A code shall be typed only when Claude passes it (read from the owner's texts or
  email by Claude itself, with whatever waiting Claude likes) or when the sign-in has a code
  generator in Passwords (each 30-second code typed once, counted as used only once typed);
  without either, nothing is typed and Claude is told to read the code itself (Toni, 2026-11-22).
  A code Claude passes needs no saved sign-in chosen when the site has several.
- **FR-1376** (Experimental, for comparison; Toni, 2026-11-22: "test all approaches for robustness
  on a wide variety of web sites, and inform me what the results are".) Besides FR-1375, a texted
  or emailed code shall be typable two more ways, each chosen by Claude per call:
  (a) Latchkey finds it: when Claude asks for the code from the owner's texts or email, Latchkey
  shall type the newest code not yet used from a message that may be the site's (a text whose
  site-bound last line names another site never is; an email must name the site), that came since
  the password Latchkey last typed on that site in the last 10 minutes (else in the last 3
  minutes), without showing it to Claude; with none yet, it shall say so without an error, and
  Claude calls again when it likes. (b) Latchkey checks Claude's code: when Claude passes a code
  and asks for the check, Latchkey shall type it only if such a message holds exactly that code.
  Either way, once the code is typed and the button pressed, that message shall never be taken
  again and shall be deleted (a text) or archived (an email) at once, or at the next unlock while
  locked, only while Messages or Mail is Read & write. Neither reads anything while Messages
  (texts) or Mail (email) is Off.
- **FR-1371** Signing in shall be Claude's: Claude reads the page and decides what it shows (a
  sign-in form, a code step, a check, signed in, refused) and which buttons to press, with the
  browser tools; Latchkey only types a saved value into the field Claude names (Toni,
  2026-11-22: "Fill-only tool"). Claude names the page, the field (by its reference), what to
  type (the saved user name, the saved password, or a verification code), and, for a password
  or a code, the button to press right after. Latchkey types the value key by key as a keyboard
  does, presses that button as a click does, lets the page settle as after any click, empties
  every field it typed into that is still on the page (FR-1311), and answers with what it typed
  where and the page as it is. It never judges whether the sign-in worked, never presses a
  button Claude didn't name, and never types anything Claude didn't ask for. A user name may be
  typed without a button.
- **FR-1372** A saved password shall be typed only into a password field that isn't a box for
  one character; a user name only into a text, email, or phone field; a code into a text or
  number field, or, when the field Claude names is a box for one character, across it and the
  boxes for one character after it on the page, one character each (also a row of boxes named
  "1 of 4" to "4 of 4", Uber's, 2026-11-22; and when the page moves the focus to its next code
  box after each character, the next one is typed there, never into a field that isn't for a
  code; the boxes together then hold the code); a code only into a field that
  is one (a password field, a one-character box, or a field marked or named for a code:
  one-time-code, numeric, code, PIN, digit), and the typed value is blanked out of the answer
  (security review 2026-11-22: typed into a search box, a code could come back as page text). A
  code's text is used up only once typed. A field Latchkey can't type
  into, or one that doesn't hold what was typed, is said so, and nothing is pressed. All of it
  only on the page's own site (FR-1321, FR-1328), in the page itself, never in a frame.
- **FR-1373** The tool's description shall tell Claude to read the page after each fill and judge
  for itself, and that some sites' protection against bots turns away Latchkey's own background
  browser while letting Safari through: while the Mac is unlocked, browser_look sign_in_again
  moves the page into a background Safari tab of Claude's, where Claude signs in again; while it
  is locked, Claude tells the owner the site needs the Mac unlocked (Toni, 2026-11-22: "ensure
  the agent gets proper guidance"). It shall also say that such a site may say nothing at all:
  the same sign-in page comes back with no error, often with a hidden "reCAPTCHA" badge, and
  that Latchkey can't tell why, so Claude judges from the page (problem report 2026-11-24,
  Procare; Toni: "keep the rule, provide hints to claude").
- **FR-1374** browser_look sign_in_again on a page of a site Latchkey signs in to itself (FR-1350)
  shall, while the Mac is unlocked, move the page into a Safari tab of Claude's at the same
  address under the same name (amends FR-1351 for that page only; the next page of the site
  opens in Latchkey's own browser again: Toni, "Decide fresh each time"); while it is locked,
  say that Latchkey's own browser keeps its own sign-in for that site, copies none of Safari's,
  and that Safari's can be used once the Mac is unlocked.
- **FR-1325** When Latchkey holds no sign-in for the page's site, the answer shall say so at once.
- **FR-1326** While Sign-in is On, Claude shall be able to list the sites Latchkey can sign in to,
  with the user name for each and whether it has a verification code, never a password or code.
- **FR-1327** Every fill Latchkey makes shall go into Latchkey's activity log: the site, the user
  name, what was typed (user name, password, or code, and where the code came from), the button
  pressed, and the browser, never the secret.

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
- **FR-1352** (Withdrawn 2026-11-22: Claude moves a page into Safari itself with browser_look sign_in_again, and nothing is remembered for the next chat (Toni: "Decide fresh each time"); FR-1374. Was: When Latchkey's own sign-in can't finish on such a site (the site asks for a code
  Latchkey doesn't hold, shows a check it can't answer, or refuses the password), Latchkey shall
  use the Owner's Safari sign-in for that site as spec 005 does: while the Mac is locked, take
  Safari's cookies for the site and load the page again; while unlocked, move the page into a
  Safari tab of Claude's. The answer says that Latchkey's own sign-in couldn't finish, why, and
  that the Owner's Safari sign-in is used instead (which may sign Safari out on some sites, as
  before). The site stays on Safari's sign-in until the Owner's next export or Remove All, or until an
  update that changes how Latchkey signs in (texted and emailed codes, typing key by key; Toni,
  2026-11-21: "do it", to try Amazon's texted code live) gives it one more try. A site
  here is every saved sign-in registered under the same name (amazon.com and
  na.account.amazon.com are one; live check 2026-11-21: Amazon's sign-in is in cookies for all of
  amazon.com, which the second saved sign-in still held back), and what Latchkey's own try left
  in its browser for it is dropped before the copy.)
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

- **FR-1360** (Withdrawn 2026-11-22: Claude reads a code from the owner's texts or email itself and passes it to logins_fill (Toni, 2026-11-22: "The agent reads the messages, archives them etc, sets a wait period they like etc"). Cleaning up is Claude's too: messages_delete, spec 002 FR-180; mail_archive, spec 008 FR-852. Was: When Claude asks Latchkey to type a code (FR-1371) and Latchkey holds no code
  generator for the site, Latchkey shall take the code from the newest text in Messages
  on this Mac that arrived after the last password it typed on that site in the last 10 minutes
  (else in the last 3 minutes; security review 2026-11-22), isn't from the Owner, and reads as a code
  text (4 to 8 digits next to a word like "code" or "OTP"; security review 2026-11-21: never a
  friend's "meet at 1830"), whoever sent it, and type it as FR-1371 does; Claude never sees it. Each
  text is used once. When none has come, the answer says so at once and Claude asks again in a
  few seconds; nothing waits. While Messages is Off in Latchkey's settings, or Latchkey can't read
  Messages, no text is used.)
- **FR-1368** (Withdrawn 2026-11-22: Claude presses the site's buttons itself, "Text me" included (FR-1371). Was: When, after the password, the site asks how to send the code (Citi, 2026-11-21: "We'll
  send a code to +1 ••• 0790", Text me / Call me), Latchkey shall press the text-message option
  (else email), never such a button before the password went; and when the site then returns
  to its sign-in form, the answer shall say the site ended the sign-in (a check), never that it
  refused the password, and it counts as no refusal. The same holds when the site returns to its
  sign-in form after the code went (Citi in Latchkey's own browser, 2026-11-22).)
- **FR-1369** (Withdrawn 2026-11-22: the guidance is in the tool's description (FR-1373); no answer judges what the site did. Was: When a site shows a check or ends the sign-in in Latchkey's own browser, the answer
  shall tell Claude that some sites' protection against bots turns away that background browser
  while letting Safari through, and what to do (Toni, 2026-11-22: "ensure the agent gets proper
  guidance"): while the Mac is unlocked, call logins_sign_in again on the page, which has moved
  into a background Safari tab of Claude's (FR-1352) or moves there with browser_look
  sign_in_again; while it is locked, that Safari is used only while the Mac is unlocked, so Claude
  tells the owner and tries again once it is. The tool's description says the same.)
- **FR-1370** (Withdrawn 2026-11-22: each fill is one step, with no waiting for a code, so no call runs long. Was: A sign-in call shall start no new step (filling, sending, looking again) once 40
  seconds have passed since it began, and shall then clear what it filled (FR-1311) and say the
  site was slow to answer, counting nothing against the saved sign-in, so its answer reaches
  Claude within the relay's 60 seconds (Costco in a Safari tab, 2026-11-22: the call passed the
  60 seconds with the password still in the page). A texted code is waited for at most 35
  seconds of a call (was 45). Time running out while the site still shows the field it was sent
  on, with no words from the site, is never a refusal and never switches the site to Safari's
  sign-in (Citi while the Mac was locked, 2026-11-22: its slow page was still signing in).)
- **FR-1361** (Withdrawn 2026-11-22: nothing waits for a code; Claude calls again (Toni: "Shouldn't the agent do that too?"). Was: One sign-in call waits for that text for as long as the call's time allows; when the
  text hasn't come by then, the answer says the site texted a code that hasn't arrived and to call
  again on the same page, and the next call takes it. A text is waited for up to 2 minutes from
  the site's request; after that, the sign-in counts as needing a code Latchkey doesn't hold
  (FR-1352's fallback follows).)
- **FR-1362** (Withdrawn 2026-11-22: Claude reads a code from the owner's texts or email itself and passes it to logins_fill (Toni, 2026-11-22: "The agent reads the messages, archives them etc, sets a wait period they like etc"). Cleaning up is Claude's too: messages_delete, spec 002 FR-180; mail_archive, spec 008 FR-852. Was: Right after Latchkey typed a code from a text (Toni, 2026-11-22: "Right after typing
  it"; it was: only after a sign-in Latchkey judged to have worked), and while Messages is Read &
  write in Latchkey's settings
  (deleting is a change), it shall delete that text in Messages (from all the
  Owner's devices, kept in Recently Deleted as Messages does), through Messages' own window in
  the background, without bringing Messages forward: at once while the Mac is unlocked, else as
  soon as it is unlocked, also after a restart in between. Only that one message, never the
  conversation. This is an exception Toni chose to never disturbing the user (Constitution IV):
  Messages' window may show that conversation. When the window can't do it (another language,
  the message not shown, Accessibility not allowed), the text stays, and Latchkey's log says why.)
- **FR-1363** (Withdrawn 2026-11-22: Claude reads a code from the owner's texts or email itself and passes it to logins_fill (Toni, 2026-11-22: "The agent reads the messages, archives them etc, sets a wait period they like etc"). Cleaning up is Claude's too: messages_delete, spec 002 FR-180; mail_archive, spec 008 FR-852. Was: Latchkey's log records each code text used and deleted (when, the site, never the
  code or the text).)

### Codes emailed to the Owner (Toni, 2026-11-21)

Toni, 2026-11-21: "Email and SMS both"; asked, "Mark read, archive"; and "always prefer direct
MCP instead of Apple Mail tricks. only if the agent says they're not able to access emails,
start Apple Mail. Ask the agent specifically if they can access emails. If they can't find it,
we can't find it via Apple Mail either"; then "yes, script Mail for archiving anyway".

- **FR-1364** (Withdrawn 2026-11-22: Claude reads a code from the owner's texts or email itself and passes it to logins_fill (Toni, 2026-11-22: "The agent reads the messages, archives them etc, sets a wait period they like etc"). Cleaning up is Claude's too: messages_delete, spec 002 FR-180; mail_archive, spec 008 FR-852. Was: When Claude asks for a code and no text with one has arrived, the answer shall ask
  Claude whether it can read the Owner's email with a tool of its own. When it can, Claude finds
  the code and passes it to the next call, which types it; when Claude's tool can't find it, Latchkey shall not look in Apple Mail (the same mailbox).
  A code Claude passes is the code alone (4 to 10 letters or digits). A text that arrives still
  counts (FR-1360).)
- **FR-1365** (Withdrawn 2026-11-22: Claude reads a code from the owner's texts or email itself and passes it to logins_fill (Toni, 2026-11-22: "The agent reads the messages, archives them etc, sets a wait period they like etc"). Cleaning up is Claude's too: messages_delete, spec 002 FR-180; mail_archive, spec 008 FR-852. Was: Only when Claude says it has no tool for the Owner's email shall Latchkey read
  Apple Mail on this Mac for the code: an email received in the time of FR-1360, not in a sent,
  draft, or deleted mailbox, read from Mail's own files (its text, never through its window),
  under FR-1360's rules for a code and only from an email naming the site (its sender or text
  holds the site's registered name, like "citi"; security review 2026-11-21); Apple Mail is started in the background, hidden, when it
  isn't running.)
- **FR-1366** (Withdrawn 2026-11-22: Claude reads a code from the owner's texts or email itself and passes it to logins_fill (Toni, 2026-11-22: "The agent reads the messages, archives them etc, sets a wait period they like etc"). Cleaning up is Claude's too: messages_delete, spec 002 FR-180; mail_archive, spec 008 FR-852. Was: Right after Latchkey typed an emailed code (it was: after a sign-in that worked), that email shall be marked read
  and moved to its account's archive mailbox through Mail's scripting, never its window: the one
  Latchkey read, and the one holding the exact code Claude passed when Mail has it (received in
  the last 10 minutes); Mail is never started for this. Only while the Mac is unlocked (Mail
  froze when scripted behind the lock, 2026-11-02), else at the next unlock. When Mail doesn't
  have the email, Claude is asked to archive it with its own tool. Without permission to script
  Mail, the email stays and Latchkey's log says why (no question is shown to the Owner during
  use); "Control Mail" is one of the permissions Latchkey asks for in setup and Settings →
  Permissions (FR-623), since 2026-11-21.)
- **FR-1367** (Withdrawn 2026-11-22: Claude reads a code from the owner's texts or email itself and passes it to logins_fill (Toni, 2026-11-22: "The agent reads the messages, archives them etc, sets a wait period they like etc"). Cleaning up is Claude's too: messages_delete, spec 002 FR-180; mail_archive, spec 008 FR-852. Was: Latchkey's log records each code email used and archived (when, the site, never the
  code or the text).)

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

- A site that sends a code by text or email after the password: Claude reads it with Messages or
  its email tool (or Mail's tools) and passes it (FR-1375).
- A site that asks for a new-device check, or a captcha: Claude sees it on the page; Latchkey
  never answers it.
- A site whose protection against bots turns Latchkey's own browser away: Claude moves the page
  into Safari while unlocked, or tells the Owner the site needs the Mac unlocked (FR-1373).
- A sign-in form inside a frame from another site: not filled (FR-1321).
- A lookalike address (`amaz0n.com`): no match, nothing filled.
- Several sign-ins for one site: Claude names the user name; without one, Latchkey asks Claude to
  choose from the list (not for a code Claude passes).
- The exported file: saved in Latchkey's own folder, never iCloud Drive; that folder is left out
  of Time Machine; the file lives for seconds.
- The Owner is using Passwords when they click Export: Latchkey uses its open window and leaves
  it open afterwards.
