# Status

Last updated: 2026-11-23 (the hosted relay's server moved out of this repository; CI sets up uv for Semgrep again; Xcode tests in Shell, spec 004 FR-335; development in Claude Code cloud sessions; Shell builds: task sandbox off, asset-catalog daemon per command; builds work in Shell, spec 004 FR-333 and FR-334; Sign-in built, spec 013; Claude's feedback tool, reports copied to the Mac's Feedback folder; pages are read once they stop changing; every issue becomes a regression case; clicks press down and up before clicking, so Gmail's buttons answer; signed-in sites in Safari tabs of Claude's while unlocked; sign-in cookies in Latchkey's log, for Safari's Target sign-outs; full traces everywhere, in daily files, for evals; Claude's pages always in Latchkey's own browser, by name, with dialogs Claude answers; the locked browser takes Safari's cookies again with every page; public download on GitHub with a new-version notice; never disturb the user: Mail, WhatsApp sending, Notes' window editing, Messages' window actions, Reminders' window setters removed; test sweep on exit; releases are tags on commits; cloud-only files read again; machine list shows Latchkey versions; WhatsApp built; Add to Claude button; plugin withdrawn; README rewritten as a short product page; relay web pages redone; Linux home server paired; spec 010 shipped)

Xcode signing ready (2026-10-20): Toni's Xcode account has a valid "Apple Development" certificate
(certificate expires 2027-07-22). Keep the team ID out of committed project files
(open source); put it in a gitignored `macos/Local.xcconfig` as `DEVELOPMENT_TEAM`.

## Open acceptance (CLAUDE.md, "Done means Toni's conditions")

Each row is a condition Toni asked about. VERIFIED only by a live run in that exact condition
with the installed version; SCHEDULED waits for a state only Toni can produce.

| Condition (Toni's words) | Status | Evidence |
|---|---|---|
| Citi, fresh sign-in, Mac unlocked, background | VERIFIED | 0.8.218, 10:17 2026-11-22, Latchkey's own browser, dashboard shown (old one-call tool) |
| Citi, fresh sign-in, Mac locked, background | VERIFIED | 0.8.226, 16:55–17:01 2026-11-22, Mac locked since 15:22, Latchkey's own browser, fresh Claude Code sessions: all three ways of typing the texted code reached the Citibank Account Dashboard |
| Citi, already signed in, Mac locked | VERIFIED | 0.8.219, 10:2x 2026-11-22, the dashboard opened with Latchkey's kept sign-in |
| GitHub, fresh sign-in, Mac locked, with logins_fill and a texted code | VERIFIED | 0.8.221, 12:09 2026-11-22, fresh Claude Code session, dashboard shown |
| Texted code deleted after use | VERIFIED | 0.8.222, 12:52 2026-11-22, at unlock; gone from its conversation in chat.db |
| Mail tools find and read, Mac locked | VERIFIED | 0.8.221, 12:09 2026-11-22, fresh session listed 30 and read the newest |
| Costco sign-in | NOT VERIFIED | refused in both browsers with no words; Toni to check the saved password |
| eBay sign-in | NOT VERIFIED | eBay's human check in both browsers; only Toni can answer it |

### Codes experiment (0.8.223, 2026-11-22, fresh Claude Code sessions, Latchkey's own browser)

Way 1 = Claude reads the code and passes it; way 2 = `code_from` (Latchkey finds it, Claude never
sees it); way 3 = `check_code` (Claude's code typed only if a message holds it). Each run signed
out first; checked from the raw page reads and Latchkey's log (cookies, deletes), not the
agent's words.

| Site (code) | Screen | Way 1 | Way 2 | Way 3 |
|---|---|---|---|---|
| GitHub (text) | unlocked 13:50–13:57 | VERIFIED | VERIFIED | VERIFIED |
| United (text) | unlocked 14:08–14:12 | VERIFIED | VERIFIED | VERIFIED |
| LinkedIn (email) | unlocked 14:13–14:18 | no code asked | VERIFIED | no code asked |
| Nike (email) | locked 14:29–14:35 | VERIFIED | VERIFIED | VERIFIED |
| PayPal (text) | locked 14:35–14:40 | no code asked | VERIFIED | no code asked |
| Airbnb (text) | locked/unlocked 15:00–15:05 | VERIFIED | VERIFIED | VERIFIED (2nd code passed without the check) |
| Best Buy (email) | locked/unlocked 14:45–15:42 | VERIFIED (40 calls) | VERIFIED | VERIFIED (0.8.224; the first try, on 0.8.223, was sent home by its "Please wait" check) |
| Uber (text, 4 boxes) | locked 16:14–16:21 | VERIFIED (0.8.225) | VERIFIED (0.8.225) | NOT VERIFIED: after about 9 sign-ins Uber refused texts and offered only WhatsApp |
| Etsy (email) | locked 16:50–16:55 | VERIFIED (0.8.226) | VERIFIED (0.8.226) | VERIFIED (0.8.226; a stale code refused first) |
| Amazon | unlocked and locked | NOT VERIFIED: its "I am human" box (before the form, or after the code), never ticked | same | same |
| Citi (bank, text) | locked 16:55–17:01 | VERIFIED (0.8.226) | VERIFIED (0.8.226) | VERIFIED (0.8.226) |
| Chase (bank) | locked 17:01–17:10 | NOT VERIFIED: its code step was blank (the page counted as hidden); fixed in 0.8.228 (pages visible, unit-tested), not yet run live on Chase | same | same |
| Bank of America (bank, text) | unlocked 18:59–19:06 | VERIFIED (0.8.226) | VERIFIED (0.8.226) | VERIFIED (0.8.226) |

Not yet run: Capital One, Amex, US Bank, Discover, Fidelity, Schwab (Toni, 2026-11-22: "wrap up
the work. what doesn't work, doesn't work"). Leftovers: two identical Uber code texts and two
Bank of America code texts couldn't be deleted by 0.8.226 (fixed in 0.8.228 and the release after
it; deleted after that install); one Uber code went to WhatsApp (no delete there).
| IKEA, Walmart, Target | unlocked | password only, no code asked: signed in all 9 runs | | |

Comparison: all three ways are as reliable as each other once the page works; every failure was
the page (shadow roots, code boxes, hidden menus, focus-moving widgets, hidden pages) or a site's
bot wall. Way 2 uses the fewest calls (Citi 9 against 17 and 15) and Claude never sees the code;
way 3 refused a stale code twice (Etsy, Airbnb), costing a retry.

Fixed during it (0.8.224 to 0.8.226): Etsy's fields in shadow roots, Uber's "1 of 4" boxes and
widgets that move the focus, GitHub's real "More options" list, a toggle's state (Amazon's
returns). Two Uber code texts couldn't be deleted (the window didn't show them); the next
failure says why.

## Current phase

The hosted relay's server moved out of this repository (Toni, 2026-11-23): its deployment
scripts, the infra workflow and the server's description now live in a private repository.
Latchkey keeps the app, its release pipeline (`relay-image.yml` publishes and signs the relay
image; hosts that verify the signature pull it) and generic self-hosting docs, with a locked-down
Docker Compose and Caddy example in docs/self-hosting.md.

Fill-only sign-in (Toni, 2026-11-22: "Shouldn't the code just provide what's happening in the
browser and the agent makes the presumptions?"; then "Fill-only tool", "No cap", "Decide fresh
each time", "Shouldnt tve agent do that too?", "Right after typing it"; spec 013 FR-1371 to
FR-1374): logins_sign_in, which ran a whole sign-in and guessed what each page meant, is replaced
by logins_fill. Claude names the field, what to type (user name, password, or a code), and the
button to press after; Latchkey types, presses, empties what it typed, and answers with the page
as it is. Claude presses "Text me" and the like itself, judges every page, and moves a page into
Safari with sign_in_again while unlocked (nothing remembered). No refusal count, no fallback
list, no waiting for codes (a code text is looked for since the last password typed on the site
in 10 minutes; none: said at once), and a code's text or email is cleaned up right after it is
typed. Removed: SignInFlow (the guessing), the fallback list in OwnSessions, the delivery and
waiting parts of TextedCodes, the refusal count in SignInStore.
Codes are Claude's too (Toni, 2026-11-22: "The agent reads the messages, archives them etc, sets
a wait period they like etc"; then "Give Claude a delete", "Claude reads Apple Mail"): Latchkey no
longer reads Messages or Mail for codes. logins_fill types a code Claude passes, or the one from
Passwords. Claude reads a texted code with messages_find and messages_read and deletes the text
with the new messages_delete (spec 002 FR-180, through Messages' window in the background, at the
next unlock while locked); an emailed one with its own email tool, else the new Mail capability
(mail_find, mail_read, mail_archive; spec 008 FR-850 to FR-853, back in part, read and archive
only). TextedCodes became PendingCleanup (deletes and archives now, or at the next unlock).
My 11:01 install of the fill-only version restarted Latchkey during Toni's Target order chat and
renamed its sign-in tool, so that chat lost its page and tool. Since the research on tool design
and agent process (Toni's decisions, 2026-11-22): `install.sh` waits until no call runs and none
has for 10 minutes (from the app's running-calls folder, spec 001 FR-667), gives up after 30;
CLAUDE.md has "Done means Toni's conditions" (VERIFIED / NOT VERIFIED / SCHEDULED rows, the
"Open acceptance" table above), batch installs, a security review before commit for sign-in,
browser, Messages, Mail; Constitution X "a tool reports; Claude judges"; `.claude/rules/`
tool-design.md, secrets-and-pages.md, relay.md; the end-of-turn hook sends back once a "works"
or "done" without rows; CLAUDE.md is 254 lines (was 371; cloud sessions, commands, hooks, and
worktree details moved to docs/).
Live with 0.8.221 (Mac locked): a fresh Claude Code session signed in to GitHub with only the new
tools: user name and password with logins_fill, SMS chosen itself, the code read with
messages_read, typed with logins_fill, the dashboard; the code text queued for deletion at the
next unlock. mail_find listed 30 emails and mail_read read the newest. Its two reports, fixed:
links in GitHub's closed "More options" menu weren't listed (now listed, marked, spec 005
FR-464), and a code it passed still asked which of seven GitHub sign-ins (no longer). mail_find
now says when it stops at 30.

CI green again (2026-11-22): every CI run on main had failed since 2026-11-21, when the deploy
gate's Semgrep (`make semgrep`, run with uvx) reached CI: ubuntu-latest has no uv ("uvx: not
found"). The workflow now sets up uv (astral-sh/setup-uv, pinned to a commit);
`scripts/tests/ci_tools_test.sh` fails when the Makefile uses uvx and CI doesn't set up uv. The
first green-security run then failed `TestCalls` ("mac offline"): hub tests called the Mac right
after dialing, before the hub held the connection; the tests' `dial` now waits until the hub
holds it, so every hub test starts online.

Xcode tests in Shell (Toni, 2026-11-21: "Test step outside fence"; spec 004 FR-335): no app's
unit tests could run through `shell_run`. macOS opens an app for a sandboxed program without
the program's environment, so the test app Xcode opens never got its test settings and
xcodebuild gave up after about six minutes ("The test runner hung before establishing
connection"). With `open` declared, the job's `xcodebuild test` now builds inside the fence and
runs the test step through `LatchkeyXcodeTests`, a small program in Latchkey's app that the
fence starts outside and that runs only `xcodebuild test-without-building`; without `open`,
tests are refused at once. Regression case `regressions.shell_xcode_tests_in_fence`.

Development in Claude Code cloud sessions (Toni, 2026-11-21; CLAUDE.md "Cloud sessions"): the
hooks know a cloud session (`CLAUDE_CODE_REMOTE=true`). Session start runs
`scripts/cloud-setup.sh` (jq, lsof, the pinned ShellCheck, uv, and Go modules, tools and test
builds warmed in the background), skips `tidy.sh`, and still reports loose ends; no `tidy.sh`
after a push; the guard is unchanged, and the private-values check reads the values from
`LATCHKEY_PRIVATE_*` environment variables there and refuses a push when none are set. Relay
and Linux work runs in the VM; the Mac app builds and tests on the Mac through Latchkey's
`shell_run` from a clone in the command's scratch folder; deploys, Linux releases, installs and
live checks stay in a local session. Checked in `docker run ubuntu:24.04`: the real session-start
hook on a bare image, then `make test`, `make lint`, `make security` and `make script-tests`
(`scripts/tests/hooks_cloud_test.sh` covers the hooks in both places), on 4 CPUs like the
cloud VM. Found on the way: the pinned linters built with an older Go refuse the relay's 1.27
(the setup puts the relay's toolchain first); `make -C linux lint` on Linux checks the Linux-only
files the Mac never lints, and found 8 issues (fixed: tighter cgroup modes, a bounded `pgrep`);
five relay tests raced on a busy VM, one hanging the package for 10 minutes (they now wait for
the call, the stored row, and the tool list instead of fixed times). The cloud
environment "Default" has the six `LATCHKEY_PRIVATE_…` variables (added through Latchkey's
browser, 2026-11-21) and Full network access, so the three domains `make security` needs are
reachable.

Builds in Shell (Toni, 2026-11-21: "fix and test"; a feedback report): no Xcode project could
build through `shell_run`, locked or unlocked, since SwiftPM, Xcode, and the Swift compiler start
sandboxes of their own and macOS refuses one inside Latchkey's fence. Each command now gets
`xcodebuild` and `swift` that turn those off, first on its PATH (so `make` and scripts use them
too), and Xcode's matching settings in `XCODE_XCCONFIG_FILE`; the fence still applies. An answer
tells a program starting its own sandbox apart from a refused write. Tests build a SwiftUI
package with `swift build` and `xcodebuild` inside the fence; a regression case builds this app.

Security emails (Toni, 2026-11-21; spec 001 FR-696 to FR-699, plan D5): the relay emails the
Owner whenever a machine is paired, an app is allowed on the consent page (not on a refresh), or
the account is recovered, with the time in UTC, the request's IP address, and links to the
account page and recovery. Sent in the background after the change, never holding it up; at
most 10 per account at once, then one every 6 minutes. Other accounts can't silence them: each
account's first 3 in 6 hours have a relay-wide allowance and 4 sending slots of their own,
and every refusal not of the account's own doing is logged at Error (FR-699a, from the
security reviews). Built and tested in the relay; deploy pending.

Sign-in (spec 013, built 2026-11-21): Latchkey signs in on Claude's pages with the owner's
passwords and verification codes from Passwords' CSV export, filled by Latchkey, never seen by
Claude. Two tools, `logins_find` and `logins_sign_in`; a Sign-in setting, On by default; the
one-touch export from the menu, Settings, setup (an optional sixth step), and a weekly
notification; copies in one Keychain item, removed with Remove All or an uninstall. Security
reviews of the build added: the Public Suffix List (no subdomain fills under shared hosts), the
page's site from the browser's own address with fills in a script world of Latchkey's own, the
save panel cancelled on anything unexpected, and Claude's command line and Files can't read the
import folder. Passkeys need the paid Apple Developer Program.
The first real export (Toni, 2026-11-21 09:41, 0.8.175) was very slow and stopped at the save
panel's Go to Folder, telling it only in Settings: each look walked Passwords' whole window
(1,045 passwords, 85 s a look), and keys sent to Passwords alone never reach the save panel (its
own process). 0.8.176 looks only in dialogs (0.07 s), posts the two key presses as the keyboard
does while Passwords is in front, shows each step in the menu and Settings, and sends a
notification when it stops (the import already sends one when it's done). 0.8.177: after a stop,
Latchkey checks the save panel closed and, for 10 minutes, wipes a file of the export's name
saved anywhere a panel may put it (FR-1307; Toni asked whether a stale file is left in
Downloads; none was).
Toni's export with 0.8.177 (2026-11-21 10:41): done in 10 s, 1,026 sign-ins (Passwords' other
19 items have no web address), none with a verification code in Passwords. Live sign-in through
the hosted relay: homerecording.com signed in, no password in any answer, but the tool said "a
check" (a hidden reCAPTCHA frame from Google's ad script); 0.8.178 counts only a challenge the
page shows, and logins_find starts with totals and says how many have codes (a feedback report).
Latchkey's own sign-ins (0.8.179; Toni: "can it not sync cookies … so it doesn't log my real
browser out?"; spec 013 FR-1350 to FR-1355): for the 871 sites Latchkey has a password for, its
own browser copies none of Safari's cookies, locked or unlocked, and stays its own browser
while unlocked; Claude signs in with logins_sign_in, and the session is kept in a Keychain item
of Latchkey's across restarts. Where that can't finish (no code, a check, a refusal), the site
uses Safari's sign-in as before until the next export. Live check (0.8.181, Mac locked): groups
logins, browser, regressions-browser: 49 worked, 4 skipped (unlocked only, or the test
sign-in), 2 failed; homerecording.com was still signed in with the kept session after two
restarts. The two failures: one case expected a sign-in form where the kept session needed
none (the case was updated), and Amazon stayed signed out after the fallback, because a second
sign-in saved for na.account.amazon.com still held back Safari's amazon.com cookies. 0.8.182
falls back every sign-in under the same registered name, drops what Latchkey's own try left,
and opens the page again instead of reloading a code step; 0.8.183 also applies that to a
fallback recorded earlier. Rechecked live (0.8.183, locked): Amazon's order history opened
signed in with Safari's sign-in. That check texted Toni two Amazon codes Latchkey couldn't use
(the second from reloading the code step, fixed in 0.8.182). Texted codes (0.8.184; Toni:
"Ensure you can use OTP. Mark them read and archive/delete after use"; spec 013 FR-1360 to
FR-1363): Latchkey takes a code a site texts from Messages, fills it, and deletes the text in
Messages' window, at once while unlocked, else at the next unlock. Not yet tried live: the
delete in Messages' window (the Mac was locked); the case `logins.texted_code_deleted` checks
the log after the next code used. Emailed codes (0.8.186; Toni: "Email and SMS both", Claude's
own email tool first; spec 013 FR-1364 to FR-1367): after 20 s with no text, Claude is asked
whether it can read the owner's email and passes the code; only without an email tool does
Latchkey read Apple Mail's files (Mail's previews come hours late, so the email files are
decoded), starting Mail hidden. The code email is then marked read and archived through Mail's
scripting while unlocked. Not yet tried live: reading a real code email and the archive script.
Citi (Toni, 2026-11-21, 0.8.185): signing in failed and the page got lost. Found on Citi's own
login page: its user ID field has an input mask that keeps only what comes with real key
presses ("dummyuser" became "uu" when set in one go), so the form went with a bad user ID;
Latchkey quoted the page's "Skip to Content" link (a live region) as Citi's error; two such
tries counted as refusals and blocked the saved password though it was never checked; and a
Safari tab of Claude's whose page redirected after the load's 15 s limit lost its mark, so
later calls said "That page isn't open" and each new page left another Citi tab. 0.8.187: fields
are typed key by key (key events with codes, beforeinput, the caret), a field that doesn't hold
what was typed sends nothing and counts nothing ("couldn't fill"), the site's error is read
from error elements first and never from a link, and a tab of Claude's own stays found while
every other tab in its window is as it was. Rerun with 0.8.187: the password went through;
then Citi asked how to send the code (Text me / Call me), which Latchkey read as a refusal
with Citi's scam banner as the reason; pressing Text me by script sent the page back to Citi's
signed-out home (Citi's bot protection, not worked around). 0.8.188: after the password, a
"how to send the code" step is answered with its text option (FR-1368), a site that then ends
the sign-in is a check, not a refusal, long notices and banners are never the site's words,
and "Sign on" buttons count. Citi itself needs Toni to sign in once in Safari.
Live Amazon test with codes (Toni: "do it", 2026-11-21 17:50, 0.8.190, Mac unlocked): sites that
fell back under older sign-in rules (Amazon) got one more try of Latchkey's own sign-in; Amazon
took the password and asked for no code this time, but showed its "I am human" checkbox, which
Latchkey answered as signed in. 0.8.191 reads a page that asks to confirm being human as a
check. A code text or email is still not tried live: no site has sent one since.
First live sign-in with a code (2026-11-21 18:26, 0.8.192): IKEA by its one-time-code way; a
fresh Claude had no working email tool, passed no_email_access, and Latchkey read the code from
Apple Mail and signed in. Archiving the code email failed: macOS hadn't been asked to let
Latchkey control Mail (and the log line named Messages). 0.8.193 adds "Control Mail" to the
permissions Latchkey asks for (setup and Settings → Permissions). Before that: Banner Life's
login is saved at access.bannerlife.com but signs in at login.bannerlife.com, so 0.8.192 fills
any page of the same registered site, as Passwords does (Banner then refused the saved
password); Amazon took the password without a code.
First live sign-in with a TEXTED code (Toni: "keep doing it until you're successful",
2026-11-21 19:42 and 19:44, 0.8.198): GitHub (tonimelisma) after the password showed a passkey
page; Latchkey picked its SMS option, pressed Send SMS, took GitHub's text from Messages, filled
it, signed in, and deleted the text (in Messages' Recently Deleted, checked in chat.db). What it
took, each found live: United's six code boxes have no length limit (taken for one field, the
digits shifted a box), a hidden browser fires no focus events (sent now, with a paste as
fallback), an empty box's delete acted as Backspace, a masked user name read as a failed fill
(which also wrongly switched United to Safari), a text sent before the code page was ignored,
GitHub's passkey page read as "signed in". Amazon, United, and GitHub each skipped the code
once they trusted Latchkey's browser. The "Signed in" answer now says how the code came.
Setup's Ask Now did nothing for Mail (Toni, 2026-11-21): macOS had Latchkey's control of Mail
turned off from earlier and never asks again. 0.8.200 says so under the button and opens
System Settings → Automation; the text macOS shows with its question names Mail and why; and
per Apple's guidelines (Privacy: a button before macOS's question isn't titled "Allow") the
Permissions buttons say "Ask…" or "Open Settings…".
Emailed codes (0.8.201): IKEA's plain text glues the code to the next word ("code.123456Please"),
so only the HTML part shows it apart; both parts are read now. Scratch folders (0.8.201; Toni:
"Delete big ones outright"): the Mac's disk filled (Trash 9.8 GB, 63 scratch folders of other
Claude sessions' Xcode builds); a scratch folder of 100 MB or more is now deleted, not trashed.
Emailed code end to end (0.8.205, 2026-11-21 21:54): a fresh Claude signed in to IKEA with the
code from Apple Mail, and Latchkey marked that email read and archived it (checked in Mail's
index). Citi again (Toni: "you log in to citi!", 22:15): answered "Signed in" while Citi still
drew its "Let’s make sure it's you" page, then found no form on that page, then took Citi's six
one-character code boxes (password fields) for the password. Now a one-character password field
is a code box, that page counts as a second step (Text me is pressed), and a page that shows
nothing right after the password is looked at again for up to 3 s (0.8.212). Then Citi was
signed in in Safari by hand (Latchkey's log shows no code used), and every statement Citi lists
was already in OneDrive. Tabs (Toni: "you've left all the browser tabs open"): Claude's pages
are kept in memory only and every install restarts Latchkey, so their Safari tabs outlived
them; now Latchkey closes Claude's Safari tabs when it quits (spec 005 FR-460), a page whose
tab is gone is forgotten when closed, and a code asked for moments ago is said so instead of
"a check".
Citi by Latchkey alone (Toni: "log in to citi yourself now", unlocked): the sign-in worked (no
code asked) but answered "Safari's tabs changed": Citi sent Claude's tab on to online.citi.com,
and the check inside Safari just before each script accepted only a marked tab or an address
Latchkey loaded. Now it also takes the address Latchkey's own survey just found the tab at.
And a click that sends one of the owner's tabs to a page Latchkey can't surely tell is the same
tab (Citi's End, View All Statements) ran, but was answered "nothing was done to any tab"; it
is now answered as done, with the tab dropped as before.
Then (0.8.215, 2026-11-22 00:00) Latchkey signed in to Citi by itself in one call: password, Text
me, the texted code from Messages into the six boxes, the dashboard; the text was deleted, and
closing the page closed its tab. Last gap: Citi had fallen back to Safari's sign-in, yet its
pages opened in Latchkey's own browser with no sign-in, because Safari's Citi cookies end with
the session and didn't read as signed in; a site that fell back now opens in Safari while
unlocked (FR-1352).
Sign-in across sites, live (Toni, 2026-11-22: "Are you sure you are able to log in there now,
both when the computer is locked and when it is unlocked?", then "is logging in to several other
sites working?", 0.8.216, unlocked): Citi opened straight in a Safari tab of Claude's and signed
in in one call (texted code, text deleted); GitHub and Amazon were still signed in with
Latchkey's own sessions from the day before; United signed in in Latchkey's own browser with a
texted code. eBay showed its check in Latchkey's own browser; the page moved into a Safari tab of
Claude's, eBay sent that tab to its check page before Latchkey first found it, and the tab was
lost (and called the owner's), so it stayed open: a new tab now records the other tabs as it
opens (spec 005 FR-461). Locked, Citi can't work yet: earlier, in Latchkey's own browser, Citi
took the password and the texted code, then logged the session out, which was answered as a
refused password. A probe showed that browser's pages saw a 0×0 window at no place on the
screen, a sign of a robot; Toni: "change the background tab to be more real so this legitimate
use case can work. don't do anything malicious" and "ensure the agent gets proper guidance".
Now its pages are told of a browser-sized window at the top left (FR-462; no stand-ins for
Safari's own objects or Apple Pay), a sign-out after the code is a check, not a refusal
(FR-1368), and every such answer tells Claude why and what to do, locked or unlocked (FR-1369).
Costco: in Latchkey's own browser it answered with its error page after the password (its
sign-in carries a bot-protection service's cookies), read as a refusal; the try in a Safari tab
then passed the relay's 60 s with the password still in the field. A sign-in call now starts no
step after 40 s and clears what it filled (FR-1370). And a page script with `return` but no
`await` failed in Safari tabs ("Return statements are only valid inside functions"); it runs
as a function now (spec 005 FR-463), decided by JavaScriptCore's syntax check before it runs
(the security review found the first version could run a script twice).
Live with 0.8.218 (2026-11-22, unlocked): pages in Latchkey's own browser see a 1280×990 window
at 0,33, as Safari's do; Citi, given one more try there (sign-in rules 7), signed in in
Latchkey's own browser with its texted code and the text deleted: the browser used while the Mac
is locked, where Citi had logged the session out the day before. Not yet seen with the Mac
actually locked. eBay showed its human check in both browsers; the answer gave the new guidance
and the move into Safari kept the tab. Costco refused the saved password in both browsers, with
no words, and is blocked until the next export (the saved password may be out of date). A fresh
Claude Code session saw the new logins_sign_in description, and a script with return gave
{"twice":4} in a Safari tab.
Citi with the Mac locked (Toni: "Mac is locked now, check Citi", 0.8.218): Latchkey's own Citi
sign-in from earlier was still alive (the dashboard opened). After signing that session out, a
fresh sign-in answered "refused": Citi's page was still signing in when the call's 40 s ran out,
and running out of time counted as a refusal and switched Citi to Safari's cookies. Timers and
the window were as while unlocked. Now running out of time is never a refusal (FR-1370), and
Citi gets one more try of Latchkey's own browser (sign-in rules 8).
With 0.8.219, still locked: Citi took the password and reached its "make sure it's you" step
(the same cookies as the unlocked sign-in at 10:17), then returned to its sign-in form without
texting a code; answered correctly as Citi ending the sign-in, with the guidance (FR-1369).
Possibly Citi limiting sign-ins after about eight that day; tries stopped so the account isn't
locked. Next: the first real locked use of Citi on another day (case
regressions.logins_locked_citi_slow); if it ends the same way, look at what Citi shows after
Text me while locked.
Live check (0.8.175, Mac locked, 2026-11-21 00:54): groups logins, browser, files, shell: 51 of 51
worked. A fresh Claude signed in to the-internet.herokuapp.com as tomsmith with the fixture's test
sign-in (`logins-fixture.sh`); none of its 10 tool results held the password except the test
site's own page text, which prints it; the fixture was removed and logins_find then said
Latchkey holds none.

Claude's feedback reports (Toni, 2026-11-16; spec 001 FR-690 to FR-695): the relay offers its own
`feedback` tool, and its instructions ask Claude to file a report whenever anything done with
Latchkey didn't fully work. Reports are kept sealed on the relay and copied to the Mac as text
files in `~/Library/Application Support/Latchkey/Feedback`; no notification. To investigate,
read that folder, fix each issue, and add a regression case for it (CLAUDE.md).

Regression cases from every issue found so far (2026-11-16: commits, Toni's reports, and Claude
Code transcripts): 61 cases in the regressions groups. Six past issues can't be checked through
the tools and stay covered elsewhere: a note with a checklist refused unchanged (Latchkey can't
make a checklist note to test with); the setup window at start and the pairing after a restart
(install.sh checks both), sending to an existing Messages conversation (only a real send shows
it), and computer control's choose on a native pop-up and background typing into a web combobox
(each needs a test app or page of its own, not built yet).

Clicks in pages (2026-11-16): Gmail's "Create filter" ignored Latchkey's clicks while the Mac
was locked, because a click was `element.click()` alone and Gmail acts on the press. A click now
sends pointer and mouse down and up at the element's centre first (spec 005 research, Clicks). A click
that changes nothing on the page now says so, and browser_act's wording names what to try
before computer control, which doesn't work while locked. Gmail draws its filter form twice,
one copy over the other: an element under another is now marked, and a click on it reaches the
copy with the same text on top.
First live run of the regressions groups (2026-11-16, unlocked): 46 of 62 worked, 4 apply only
while locked. Fixed from it: page scripts with await, the page's own error words, and scripts
where the page forbids eval (Safari tabs); a link whose handler cancels the click is no longer
followed; the shell points to latchkey_log when macOS refuses its system log; five cases that
checked wrongly were rewritten (a Python crash showed a Problem Report window on Toni's screen;
`pgrep -f` matched the checking agent itself). Then fixed too: computer control types one
character per key (Calculator got "1" for "12"), a press tells text that changed (a display),
and targeting Latchkey is refused as such; Contacts' remove from group tries again when its
read-back still lists the card; a slow site still loading after 20 s says so instead of an
empty page. The second run (locked): 50 worked, the rest only apply while unlocked. Still to
run while unlocked: the computer control group and the Safari-tab cases. Third run (locked,
0.8.167): 52 worked. Open: Contacts groups and iCloud. A card and a group made through
Latchkey are taken over by iCloud about a minute later, each with a new id, and the membership
added before that is lost (seen 2026-11-16 with a test card: the group showed 0 members); the
removal case fails for the same reason. Two failures came from runs overlapping (a stale page
of an earlier case; a Costco tab that moved) and passed in the run before.

Claude's feedback reports, first day (2026-11-17): the checking agents filed ten on their own.
Seven were issues fixed the same night; three were new. Fixed: WhatsApp mentions showed bare
privacy ids, and a new-tab link in a tab of Claude's lost the page (Costco; works live). Listing
tabs while locked passed the relay's 30 s on the first call (a retry answered at once); 0.8.171's
change (not finding Claude's tab again while locked) didn't fix it. Cause: before every Safari
script, the Automation permission check (`AEDeterminePermissionToAutomateTarget`, then up to 20
more after opening Safari) ran with no limit, and macOS may wait on a napping Safari for it. Now
the check and the script share the script's limit (12 s while locked), and a check slower than
3 s or one that doesn't answer is logged under permissions, so a slow call names its step. Case
regressions.browser_locked_tabs_answer_in_time works live in 0.8.172 (lid closed and locked,
2026-11-17 18:24: browser regressions 25 worked, 3 unlocked-only skipped), and the log showed the
check taking 3 s there, which confirms where the time went.
Also fixed from the runs: a WhatsApp group sender without a name is said so, and Contacts puts
back a membership iCloud dropped when it took a new card and group over (spec 007 FR-728).

Pages are read once they stop changing (a second with nothing added or removed, at most three),
so the first read of Gmail shows the mailbox, not "Loading...". Every issue found now becomes a
case in the "regressions" group of the screen-state checks (Toni, 2026-11-16; CLAUDE.md).

Safari signed out of Target (Toni, 2026-11-15, three times that evening), found and fixed:
Target rotates its refresh token, and Claude's page in Latchkey's own browser redeemed Safari's
copy (Latchkey's log, 19:23:58), which ended Safari's sign-in. Now (Toni's rule; spec 005 FR-455
to FR-459): while the Mac is unlocked, a site the owner is signed in to opens in a background
Safari tab of Claude's with his real sign-in, other sites in Latchkey's own browser with no
copied cookies; while locked, Latchkey's own browser copies Safari's cookies as before, and a
sign-out is an accepted side effect; the copies are dropped at unlock. Also found: pages of
Latchkey's own browser count as hidden to WebKit, so Target's search showed no results there;
signed-in shopping now runs in Safari, where it works (public APIs only, Toni).

Full traces everywhere, for evals (Toni, 2026-11-15: "I want to be able to do evals on everything
that happened anywhere"; spec 001 FR-680 to FR-689, spec 010 FR-1057 to FR-1059,
`specs/001-core/contracts/trace-files.md`, constitution VI amended). The Mac, each Linux server,
and every relay now keep every call's arguments and whole result (screenshots included) and their
events in files of one day each, only ever appended to: no age limit, and no update or migration
rewrites them. The Mac's log moved out of its database into the files (encrypted as before, the
tamper chain unchanged); the first start copies the database in unchanged and leaves it on disk
as it was (measured on a copy of Toni's log: 22,569 entries, 190 MB, 2.2 s). A Linux server's
files are plain, readable only by the Owner, nothing cut any more; the old `activity.jsonl` is
still read. The relay's are encrypted with a key from its key file, in a folder per account,
removed with the account; below 2 GiB free it stops writing them and never deletes old ones.
One export line everywhere, joined by call id: Export… in the Activity window, `latchkey
activity export` on a server, `relay trace export <email>` for the operator, and Download full
activity on the account page. Found on the way: the Linux end-to-end check had been failing on
main since the machine list began naming Latchkey's version; fixed.

Dead code removed (Toni, 2026-11-15: "remove all dead code"): Safari's tab and window of Claude's
own (its memory file, the Settings value, idle closing, the scripts only it used), a Mail script
named in CLAUDE.md that no longer existed, the Messages helpers of the window actions removed on
2026-11-07, WhatsApp sending's helpers, the client list's old menu view, and other unused
helpers; two test stand-ins moved from the app into the tests. The navigation and security
tests of Claude's old tab now run on one of the Owner's tabs, where the same rules apply. Found
on the way: the offer to move the app into Applications on first launch (spec 001 FR-078) was
written but never called; it now runs. And the full browser live check (24 of 25) found that a
PDF's address timed out in Latchkey's own browser: a page that is a file is now answered at
once, and saved with download (spec 005 FR-452).

Then (Toni's report, 2026-11-15): pages of Claude's timed out because each new one copied all
3,500 Safari cookies (measured: over 100 s); now the pages share one store and take a site's
cookies when they go there (spec 005 FR-441 as amended). And a busy Bank of America tab was
told as "waiting on a dialog" (an idle Safari took 12 s to answer its first script, measured):
a tab now has 10 s, and Claude is told it may be busy or paused,
to try again, and how computer control can answer a real dialog (FR-432 as amended). While
the Mac is locked, each Safari script now has 12 s, so Claude is told within the relay's 30 s
that the tabs need the Mac unlocked (FR-430 as amended).

Pages that never freeze, one set per chat (Toni, 2026-11-15; spec 005 FR-444 to FR-451, plan
D11): on Target a "Remove item?" dialog froze Claude's background Safari tab (Latchkey can't read
or answer a background tab's dialog without bringing it forward), and two other chats loaded
their pages over the cart in Claude's one tab. Now Claude's own pages always open in Latchkey's
own browser, locked or not (Safari only for the Owner's tabs, and only in a call that names
one). Each url opened without a page name is a new page with a short name (like p4k2) that
Claude passes on later calls, since Claude's apps send every chat over one connection (at most
10, each closed after 30 minutes unused). A confirm or prompt Claude didn't answer in advance
waits and is shown to Claude, which answers it with `browser_act` action `dialog`; Cancel after
5 minutes. An OK given with an action also answers a dialog up to 5 s later. The Settings choice
of a Safari tab or window is gone.

Sign-ins while locked (Toni, 2026-11-14; spec 005 FR-441, FR-442, plan D7): Latchkey's own
browser copied Safari's cookies once, when it started; on 2026-11-14 Amazon answered Claude
signed out there while Safari was still signed in. It now takes Safari's cookies again before
every page Claude opens (Safari's copy wins; cookies only that browser holds stay), and Claude
can ask for it with `browser_read sign_in_again`, which also loads the page again. Since
2026-11-15 (Toni: "do the undecided bits"; spec 005 FR-443, spec 001 FR-671, FR-672): every
answer from that browser begins by saying it is Latchkey's own browser, not Safari; the Mac's
state line ends "locked" or "unlocked" (the Mac tells the relay at once on a change; new
optional `screen_locked` in its state); and each lock and unlock is an event in Latchkey's log.

Public download (Toni, 2026-11-09; spec 001 FR-669, FR-670): every `make -C macos install` now
also publishes its disk image as GitHub release `mac-<x.y.z>` (asset `Latchkey.dmg`; the README
links releases/latest/download/Latchkey.dmg). Signed for development, not notarized: a
downloaded copy opens after Privacy & Security → Open Anyway, once per version. The image
carries no relay address (one image for everyone; checked before publishing). The app looks at
GitHub's releases once a day and shows "Download Latchkey x.y.z…" in its menu and in Settings
when a newer one is out. Only the newest three Mac releases are kept, so the Linux program's
release lookup keeps finding its own. Messenger was looked at again and left out (no Mac app
since 2025-12-15; the web page only).

Never disturb the user (Toni, 2026-11-07; Constitution IV, CLAUDE.md): while the Mac is
unlocked, Latchkey brings nothing to the front, drives no app the user may be using, and sends
no pointer or keys into their apps; exceptions are computer control, acting in the user's own
Safari tabs, and the shell's `open`. Removed for it, in one change (25 tools from a Mac now, was
33): all of Mail (spec 008 withdrawn; Toni: better done through mail providers' APIs), WhatsApp
sending and WhatsApp Web (spec 012: reading from WhatsApp for Mac's database only), Notes' window
editing (spec 002 FR-155 to FR-159: notes with checklists, links, or images are refused again),
Messages' window actions (FR-172 to FR-179: `messages_send` to a person or conversation only),
and Reminders' flag, tag, subtask, and section setters (spec 007: read only; moving a reminder
with subtasks to another list is refused). The README now says what works when. The screen-state
cases for those were removed, and so were the Messages send cases, which could no longer clean up
their test messages. Same day, the switched-off code went too: Notes' window editing
(NoteWindow, the window route, their tests) and Reminders' window setters (RemindersWindow, the
row planner); WhatsApp is Off or On in Settings (nothing to write); the README pictures were
redrawn (`macos/scripts/readme-shots.sh`), and `docs/use-cases.md` and `docs/screen-states.md`
say what was removed. WhatsApp sending through a background Safari tab was considered again and
left out (Toni: hit or miss while locked is not good enough). For Toni: the old "Latchkey check"
test messages in his self-conversations (Latchkey can't delete them any more), one WhatsApp test
message in his own chat, and, optionally, Latchkey's unused Mail permission in System Settings.

Spec 001 is built. Everything that doesn't need Toni is done and verified on this Mac
(2026-10-20):

- Relay: all tests pass (`make test`, including a headless-Chrome sign-up → OAuth → pairing →
  battery test), lint clean, container check passes (11 MB image).
- Real Claude Code through a private relay: passes (`make claude-check`).
- Mac app: 32 Swift tests pass (shared fixtures, Secure Enclave key, policies, trace); the real
  connection code passes `make mac-check` (battery matches pmset, a turned-off tool disappears,
  offline noticed in 35 s, reconnect in 0.1 s).

Notes:
- The OAuth server code was written before its contract tests (Constitution VII asks for tests
  first). The tests were then written against the contract and run.
- No keep-awake test runs (Toni, 2026-10-20). The helper runs once Toni approves it during setup.

## Done (2026-10-22)

The first version works end to end: Latchkey 0.1.2 installed on Toni's Mac and paired with the
hosted relay (email via Resend); real Claude called
`battery_status` and `laptop_status` through the connector, and got the immediate offline answer
after the app was quit.

## Next steps

0. Cloud-first, what only Toni can do (CLAUDE.md, "Owner setup"): the secrets, the package's
   Actions access, the updater on the Mac (`macos/scripts/updater-setup.sh`), `LATCHKEY_CHECK_TO`
   in the cloud environment. Then check on the Mac: the updater installs the first CI-tagged
   release; the relay image from the workflow is published and its signature verifies.
   First runs after the merge (2026-11-23, commit 66c726b): `mac tag` made `mac-0.8.227`;
   `linux release` stopped before tagging ("SERVER_SIGNING_KEY is neither set nor in ../.env");
   `relay image` passed its checks and was refused the push ("denied: permission_denied:
   write_package") until the package grants this repository's Actions write access.
1. Codes experiment: done and reported (table under "Open acceptance"). Open: Chase live on 0.8.228
   or later; the other banks (Capital One, Amex, US Bank, Discover, Fidelity, Schwab); Toni to
   choose which way to keep (or all three).
2. The Mac's updater isn't set up on Toni's Mac (`macos/scripts/updater-setup.sh`, once, Toni's
   step); installs ran by hand until then.

0. Sign-in's first real export (spec 013 T11, Toni's step): Latchkey's menu → Export Passwords
   to Latchkey…, one Touch ID. The first try (0.8.175) stopped at the save panel; 0.8.176 fixes
   it (above), tried on TextEdit's save panel, not yet on Passwords'.
   Afterwards: check the log shows the file taken in and deleted, and run the `logins` group
   (its test sign-in step skips once the owner's copies are in). Passkeys wait for the paid
   Apple Developer Program (spec 013 FR-1330).
1. While locked, Target's search stays empty in Latchkey's own browser (its pages count as
   hidden to WebKit, and only an undocumented setting changes that, which Toni declined); Claude
   can still open products and the cart there.
2. Changing notes with checklists, links, or images: the iCloud.com route was probed on
   2026-11-07 and stopped (spec 002 research, "Notes with checklists through iCloud.com"): the
   approval and the drawing in a hidden view work, but iCloud.com's editor takes no input
   Latchkey can give it without WebKit's private interfaces. Such notes stay read-only (Toni,
   2026-11-07, final: "Read only"). WhatsApp stays read-only from WhatsApp for Mac's database, even when
   out of date (Toni, 2026-11-07: "better than nothing").
3. Answering a calendar invitation, live: the code is in (spec 007 FR-705); the test invitation of
   2026-11-07 hadn't reached the Exchange calendar before the event was deleted.
4. Facebook Messenger is left out for good (Toni, 2026-11-09): Meta ended the Mac app on
   2025-12-15 and has no API for personal accounts, so only the hit-or-miss web page is left.
5. A downloaded copy on another Mac: the public download was checked on this Mac only (it opens
   after Open Anyway); the first person on another Mac confirms Open Anyway and setup there.
6. Notarized download and self-updating (Apple Developer Program, $99 a year): later, Toni's
   call; Sparkle is already in the app, off until an update key exists.

For Toni (only he can): delete the ~96 old "Latchkey check" test messages in his two
conversations with himself and the WhatsApp test message in his own chat; optionally switch off
Latchkey's unused Mail permission (System Settings → Privacy & Security → Automation → Latchkey).

## History (newest first; what was done and found, kept as the record)

Cloud-first, review fixes (2026-11-23, a second cloud session given the same task, whose own
implementation was superseded by the one merged below and ported onto it): the infra workflow's
`configure` failed on every run, since google-github-actions/auth writes its credentials file into
the checkout and `deploy.sh` refuses untracked files (`.gitignore` now has `gha-creds-*.json`);
Google accepts GitHub's token only for push, schedule and dispatch runs (a `pull_request_target`
or `workflow_run` run on main can carry a fork's code); hackernews-admin's IAP tunnel reaches only
this VM's SSH (a condition on its internal address; an earlier wider grant is replaced); a rerun of
`gcp-wif-setup.sh` rewrites the provider only when it differs (each write emails Toni). The Linux
program, on a host with the older, mixed cgroup layout, took `/sys/fs/cgroup` (a plain memory file
system there) for its control groups and every command failed to start ("bad file descriptor",
found in this cloud VM): it now requires a cgroup v2 file system and otherwise runs without groups,
saying so. Tests: `deploy/tests/lib_test.sh`, `linux/internal/shell` (both pass in the VM).

Cloud-first (Toni, 2026-11-23: everything happens in cloud sessions except what needs macOS;
the Mac only builds and tests the Mac app): in progress on branch `claude/latchkey-cloud-first-0xfzcv`.
So far: CI also runs the Linux program's tests and lint, the script tests, and actionlint on
the workflows (`install-lib.sh`'s idle check read GNU stat wrongly on Linux, so two script tests
had failed there); `tidy.sh` no longer deletes branches on GitHub (GitHub deletes a merged pull
request's branch itself). Releases are made on GitHub: `linux-release.yml` tags, signs (repository
secret `SERVER_SIGNING_KEY`) and publishes the Linux program whenever linux/ changes on main;
`mac-tag.yml` gives each Mac app change on main its `mac-<x.y.z>` tag; both run in the
environment `release` and also start on repository_dispatch (`linux-release`, `mac-tag`).
`release-tag.sh` takes `RELEASE_TAG_ON_MAIN=1` there (a commit on main the tip has moved past;
never a number below an already released commit).
Relay releases are automatic: `relay-image.yml` (on relay/ changes on main; environment
`production`) runs the security checks, lint and tests, publishes the multi-arch image to ghcr.io
as `<commit>` and `latest`, and signs it with cosign, keyless. The server's own updater
(`latchkey-update-apps`, every 5 minutes, as for hackernews) switches to a new `latest` only when
cosign finds it signed by that workflow on main, restarts the relay on it, and goes back to the
previous version when Docker's health check or https://<host>/healthz fails within 3 minutes
(remembering the bad image). No credentials reach the server. `deploy/deploy.sh` now only
applies configuration (relay.env, compose file, Caddy block, DNS, email domain) and restarts the
running version, under the updater's lock; image building, the upload over SSH and the
key-file database copy (long done) are gone. Tested by `deploy/tests/update_apps_test.sh`.
Infrastructure changes run in `infra.yml` (repository_dispatch `infra` with task `configure` or
`harden`; environment `infra`), signed in to Google Cloud as `latchkey-infra` through Workload
Identity Federation; `deploy/gcp-wif-setup.sh` (the owner, once, in Cloud Shell) makes the pool,
GitHub's provider (this repository and hackernews, on main), `latchkey-infra` and
`hackernews-admin`. `harden.sh` accepts the owner or exactly `latchkey-infra`; the IAP alert
leaves out the owner and both identities, and the sentinel counts their sessions as the owner's
(OS Login names `sa_<id>`, uids looked up on the server). `ci_tools_test.sh` checks that every
action is pinned and every releasing, deploying or infrastructure job is in its environment.
The Mac updates itself (`macos/scripts/auto-update.sh`): a per-user launchd agent
(`net.melisma.latchkey.updater`, written by `updater-setup.sh`, which every `make -C macos install`
runs) checks GitHub every 15 minutes, at login, and when a request file appears in
`~/Library/Caches/net.melisma.latchkey.updater/requests` (`now`, or `install-now` to skip the idle
wait), and when the newest `mac-<x.y.z>` tag on main isn't the installed version, checks that
commit out in its own clone and runs the usual install (signed with the main checkout's
Local.xcconfig, the 10-minute idle wait, publish.sh). launchd is its parent, so the install
quitting Latchkey doesn't stop it, and Claude can start it through Shell by writing a request.
Log: `~/Library/Logs/Latchkey Updater.log`. `install.sh` installs only a commit carrying CI's
tag that is the newest release (it no longer tags from the Mac). Tested by
`scripts/tests/auto_update_test.sh` and `install_checks_test.sh`; not yet run on the Mac.
Live checks from the cloud: a fresh cloud session from claude.ai runs the cases with its own
Latchkey tools (`state-check.sh prompt`, `record`, `merge`; screen state and the focus watcher
through `shell_run`; docs/cloud-sessions.md, "Live checks"). Merging goes through pull requests
(rebase), which GitHub deletes after the merge; `tidy.sh` and `loose-ends.sh` recognise rebased
work (`git cherry`). CLAUDE.md and docs/cloud-sessions.md now describe this process, with the
"Owner setup" list.

The relay's server, locked down and watched (Toni, 2026-11-21: "a high risk target"; docs/threat-model.md
"The relay's server", plan D29): `deploy/harden.sh` closes SSH to all but Google's IAP tunnel
with OS Login, gives the VM its own least-privilege account, Secure Boot and automatic updates
with a nightly reboot when needed, removes unneeded packages and services, puts hackernews (which
shares the server) in a container without root on its own network, and its deploys become pulls
by the server; the sentinel and cloud alerts email Toni on anything that shouldn't happen.
Done live 2026-11-21 (three runs, the last one quiet): only 80 and 443 open (22 to IAP only),
Secure Boot on, kernel 7.0 with all 65 pending updates, the VM on `relay-vm` (the default account
lost Editor), 44 locked audit rules, the sentinel's heartbeats in Cloud Logging, five alerts
and an uptime check, one test alert sent; the relay shares `latchkey-front` with Caddy only;
hackernews runs as uid 1000 without capabilities, its GitHub deploy job and SSH secrets removed
(hackernews 9be196f, which also made its image run as non-root); Caddy moved to the newest 2.x
by the weekly check. The relay emails the owner on a paired machine, an allowed app and a
recovery (spec 001 FR-696 to FR-699a), deployed as 50e1d08. Fixed on the way, each found by the
live runs or the automated security review: the SSH settings' undo ran out during the updates
(now applied last and checked), the Caddy check lacked a scratch /data, reruns wrote unchanged
cloud settings and the SSH permission check counted as a cloud change (each would email Toni),
the sentinel trusted process names and a host-wide "dpkg is running" flag, and the hub's Close
returned before a closed connection's last trace line (the long-flaky "traces: directory not
empty" tests). Live check after: a fresh Claude Code session saw both machines and used a tool.
All alerts reached the alert address (11 on the first day, from the runs themselves); one was a
false alarm, hackernews's own health check (wget) seen as a foreign program, fixed the same day.
hackernews's nightly backup was in the locked account's crontab, which lost docker: it now runs
from /etc/cron.d as root, and a run as cron does it wrote today's copy to its bucket through
`relay-vm`. Its deploys were checked end to end: back on the previous image, the timer found
CI's newest (9be196f), switched to it and logged it healthy.

Hands-on check of every tool (2026-11-07, Toni: "manual testing, since it looks like the automated
testing isn't picking up issues"), through the hosted relay on the installed app, unlocked and
then locked, with the screen recorded before and after each round (front app, pointer, every
window and its title): nothing on screen changed in any round. The code audit found nothing
Claude can trigger that brings an app forward or sends input, outside computer control. Found and
fixed: deleting a note or a Notes folder answered "not saved yet" and stayed in Notes' database
(Notes saves a scripted move but not a scripted delete: a delete is now a move into the
account's Recently Deleted, found by its folder type, and a folder's deletion is followed by a
move that changes nothing, which makes Notes save); WhatsApp group senders showed as «+IAE=»
(WhatsApp for Mac's member first-name field mostly holds encoded data: 3,328 of 3,374); removing
a card from a contact group answered success but left it there once iCloud had taken the card
over (the group's own record is removed now, and checked); with the display asleep and the lid
open the screen tools said the lid was closed; closing the page while locked named Safari instead
of Latchkey's own browser. Not tried: sending in Messages (its test message couldn't be deleted)
and computer control (the exception, it uses the real pointer).

Facebook Messenger (Toni, 2026-11-04; set aside 2026-11-05 "for another day"): not started, no
spec yet. Toni's choices so far: read and send; through facebook.com/messages in Safari (check
first that all chats show there, Meta recommends Chrome or Edge for encrypted chats); sending
through Messenger's own functions in the page; the first live send to Jonna Melisma, one message,
match confirmed with Toni first. Research so far: messenger.com closed in April 2026 and redirects
to facebook.com/messages; the Messenger Mac app was switched off in December 2025; chats are
end-to-end encrypted and the web restores history with a PIN; Meta flags automation (Beeper users
logged out with "automated process detected"), and the account at stake is Toni's whole
Facebook. Next: Toni opens facebook.com/messages in Safari; Claude reads the page (no clicks or
typing), then writes spec 013 for Toni's review before any code.

Notes checklist editing works again (2026-11-06): proven on the real Mac with the five checklist
cases through `macos/scripts/notes-check.sh` (create, append, edit, tick, untick, delete); Notes
comes forward for about a second per change.

Messages' window actions work again (2026-11-07): a new group, a like given and taken back, an
inline reply, an edit, an unsend, deleting a message, naming the group, and deleting whole
conversations all pass on the real Mac (macOS 27) through `macos/scripts/messages-check.sh`, in
conversations of Toni with himself, each checked in Messages' database and swept (a search finds
none left). The causes: on macOS 27 a message's text is in its input label, the tapback picker
drops a press made while it slides in, and the edit box is a different field. Naming a group
needs Messages in front for about a second (its name box takes text only then), guarded like
Notes (only after a pause in the Owner's input, stopped by it, the front given back; shared code
in `macos/App/Foreground.swift`). Next on the work list: prove Safari, Reminders, Calendar,
and WhatsApp groups (Mail while locked is proven, 2026-11-07); then Notes while locked.

Switched off on 2026-11-05 until they work on Toni's Mac (live checks found them broken):
Notes' window editing (checklist notes got mangled; such notes are refused again, checklist items
stay ☐/☑, no ticking) and Messages' window actions (`messages_change`, new groups, inline replies;
tapbacks didn't land, edits failed, the window jammed). The work list, in order: fix Notes
checklist editing; fix the Messages actions; WhatsApp reading shows messages deleted for the
Owner (done 2026-11-05: deleted messages leave once WhatsApp for Mac catches up; the real fault
was WhatsApp storing some messages twice, which Latchkey read twice, now read once); prove Safari uploads/downloads/pictures, Reminders' window steps, Calendar through the app,
WhatsApp groups, Mail while locked; Notes while locked (through iCloud.com; Shortcuts dropped
2026-11-07). Each is done only once it works on the real Mac, every live test cleans up after itself,
and nothing runs in the background (Toni, 2026-11-05).

Notes with checklists, links, or images can be changed now (2026-11-04, Toni: "editing notes
with checklists is not supported? … feels frustrating"): until now Latchkey refused every such
note, which is most real notes. Such changes go through Notes' own window in the background
(spec 002 plan D3a, FR-155 to FR-159): text in place, real checklists for `- [ ]`/`- [x]`, and
tick/untick (`notes_change` check/uncheck; Notes comes forward for about a second). Plain notes
keep the AppleScript route. With the Mac locked Notes' window has no note editor, so such
changes are answered at once with that reason (0.8.122); new notes keep ☐/☑ then. Still open: the
lid closed while unlocked (screen-state cases `notes.checklist_*`). Deleting a note is said done
only once Notes saved it (0.8.123): with the Mac locked Notes hadn't saved one test note's
deletion ("Latchkey check 1104-2355 locked list"); check it's gone after the next unlock. Same day: `notes_find` finds notes whose folder
was deleted under them (twelve old test notes were invisible to Claude); the screen-state check
sweeps every "Latchkey check" item on exit, even when stopped, and fails when any is left; the
end-of-turn hook was removed (Toni).

Six gaps closed together (2026-11-05, Toni: "add everything missing"), each built by a helper,
merged and tested together (33 tools now):
- Calendar: answer invitations, invite and remove people, change others' events (spec 007
  FR-704 to FR-708, plan D7), through EventKit calls Apple doesn't document: an exception to
  Constitution IV approved by Toni 2026-11-05, recorded in the constitution. Works in every
  screen state; checked live unlocked (nothing sent to anyone).
- Safari: key presses, hover, scroll, dropdowns, file upload, download, and a picture of the
  page when the screen can't be captured (spec 005 FR-433 to FR-440). Checked in real Safari
  unlocked for keys, hover, scroll, dropdowns; on 2026-11-07 also uploads (file field and drop
  place), downloads (a link, a file the page makes, a PDF), and the picture, through Latchkey's
  own tools in real Safari on the check's local page (every file removed after). The picture
  Latchkey draws when the screen can't be captured is still checked only in WebKit.
- Reminders: flags, tags, subtasks, sections read from Reminders' database; set through its
  window (unlocked only); no change loses them (spec 007 FR-714 to FR-719). Removing a tag isn't
  possible yet. Checked live 2026-11-07 in a test list (deleted after): flag and tag work; making
  a subtask worked but was reported as failed, because Reminders on macOS 27 drops the selection
  after the indent; fixed by letting Reminders' saved data decide. Sections can only be checked
  in a list that already has one (Latchkey can't make sections).
- Mail: send, reply, forward, and draft without Mail's window, through a temporary signature
  (spec 008 FR-841 to FR-845); the forward that added Toni to To is fixed. Checked unlocked;
  sending while locked works too (2026-11-07, 0.8.142: a test email to Toni sent with the Mac
  locked reached Sent and the Inbox, then was deleted).
- Messages: new groups, tapbacks, inline replies, edit, unsend, delete a message or
  conversation; reading shows tapbacks, replies, edits (spec 002 FR-170 to FR-178). Through
  Messages' window, unlocked only; every one of them, and naming a group, checked live
  (2026-11-07).
- WhatsApp: replies, reactions, delete on both paths; WhatsApp for Mac's window is the fallback
  again for text, files, replies (spec 012 FR-1245 to FR-1250). Checked live in the self chat;
  groups and people without a known number not yet.

Next: changing notes with checklists, links, or images, in any screen state, through iCloud.com
in Latchkey's own browser (in the background, so it disturbs no one). Shortcuts is dropped (Toni, 2026-11-07: "this approach is broken, remove it"): Latchkey
could add a signed shortcut by itself in the background, and its Notes action made the note, but
running it put up "Allow … to output 1 note?" on the Owner's screen, and deleting a shortcut
needs Shortcuts' window in front. Don't propose Shortcuts again.

Releases are tags on commits (2026-11-04, Toni): parallel sessions bumped the version file to the
same number, and a rebase drops the second, identical bump without a conflict, so two different
builds could both be 0.8.112. Now `make -C macos install` and `make -C linux release` tag the
commit (which must be origin/main) with the highest `mac-` / `linux-` tag + 1 and push the tag;
GitHub refuses a taken name and the next number is tried; a commit already tagged keeps its number.
No version lives in files any more. Tested in `scripts/tests/release_tag_test.sh` (two sessions
racing for one number). The installed 0.8.112 was tagged by hand as the starting point, so the
first install with tags is 0.8.113. Tags are named for their program (Toni): `mac-0.8.113`,
`linux-0.1.5`; the first Mac tags were renamed from `v…`. Linux 0.1.4 is the bridge: published
as `server-v0.1.4` (the only name 0.1.3 looks for) with an updater that reads both names, and
tagged `linux-0.1.4` too so the count goes on; from 0.1.5 Linux releases are `linux-…`. Check
that purkki reports 0.1.4 within a day (Claude's machine list shows its version).

Reading cloud-only files fixed in Mac 0.8.112 (2026-11-04, bug report: Claude couldn't read a
green card photo in OneDrive): `files_read` asked macOS to download such files with the iCloud
call, which macOS refused to the installed app ("you don't have permission"), and gave up there.
Now it downloads through file coordination first (any cloud folder: OneDrive, iCloud Drive,
Dropbox, Google Drive), falls back to the old call, still tries the read, and puts macOS's error
codes in the answer and in `latchkey_log` (no file names) when something fails; every other
unexpected Files error carries the codes too (spec 003 plan D2). Why macOS refuses that one call
to the app but not to a plain program is not known; the codes in the log will show it if
coordination ever fails too.

Claude's machine list shows each machine's Latchkey version beside its OS version (2026-11-04,
relay only; spec 010 FR-1006): the versions each machine reports when it connects, already kept
by the relay and shown on the account page. Its deploy found that the code scanner had flagged
WhatsApp's queries and the Safari dialog note since they were written (fixed SQL pieces and text for
Claude, no hole); they carry reviewed markers now (Mac 0.8.110, no behavior change).

Follow-up of 2026-11-04 (Toni: "fix everything, properly"), in Mac 0.8.109 and Linux 0.1.1:
a page's own dialogs never make Claude wait (spec 005 FR-432): reproduced in real Safari, a
dialog waiting in a tab blocks every script, its text, and its source until the 25 s limit
(the likely cause of the locked-Mac stalls); now Latchkey's answers go into the page with each
action (`confirm`, `prompt_text`; Cancel otherwise, reset right after; the Owner's tab gets its
own dialogs back), and a page already waiting is told within 2 s. Also in it: the Mac tests,
calls cut off by a quit or crash, and `latchkey_log` on Linux (the paragraphs below). #5
settled from WebKit's source: a background press goes only to the pressed element or inside
it, and scrolls nothing. Linux 0.1.2: the audit check no longer names the server's first call
missing (it asked the relay from that call's own time, which the relay records a moment
earlier; spec 010 research).

Full Mac test suite reliable again (2026-11-03, released in 0.8.109): the Automation check blocked Swift's shared threads (app bug, fixed: it now waits on a GCD thread), Mail, Messages, and WhatsApp closed a database twice when its layout check failed (app bug, fixed), and test pages now wait for WebKit's own "finished" (spec 001 research.md); 845 pass at load 19 and 86.

Bug report of 2026-11-03 (a claim form in background Safari, emails to PDF) fixed in 0.8.104 (0.8.105 keeps a queued email's recipients and subject out of `latchkey_log`, security review):
zsh here-documents and `=(…)` work in Shell's fence (`TMPPREFIX` in the scratch folder); Shell
names programs macOS stopped (from its crash reports, also in the answer after; spec 004
FR-332), and its description says apps start only with `uses` `open` (headless Chrome made a PDF
that way with `--no-sandbox`); background typing checks the focus really moved (macOS says yes
even when it didn't: reproduced on a WebKit test page), reads the value back, and names what had
the focus without a reference; every press, type, or choose names other values that changed; a
new `choose` picks a dropdown option by name (native menus by typing, web ones by pressing the
option); an app's window lists each element once (table cells were listed two or three times),
drops repeated labels, 300 at a time with `after`, `within`, `match` from the same look, and says
when it was cut (spec 006 FR-511 to FR-514). The two checkboxes checked after one press stay
unexplained: a background press changed nothing else on the test page; answers now name such
changes. Toni chose to let Claude reach his own Safari tabs like its own (spec 005, in progress
in 0.8.106, below) and to add `latchkey_log` (below). Checked live through the hosted relay: the
window list (each table cell once, labels deduped), `match`, zsh here-documents and `=(…)`,
`latchkey_log`, and in 0.8.104 the focus check refusing every typing (an app behind others names
no focused element; 0.8.106 asks the element's own focus flag, as the FormLab check showed it
stays right). Checked live on 0.8.106 through the hosted relay, the test page's own events
matching each answer: State chosen (web dropdown), Country chosen (native, no menu shown), City
typed and read back, typing into a page's text refused with where the focus is, a checkbox press
changing nothing else, and keys without a reference saying where they went. 0.8.107 and 0.8.108 look again
when a first look finds only the title bar (an app that had not built its tree yet); a cold FormLab's first look listed its whole page live on 0.8.108.

WhatsApp (spec 012) rebuilt 2026-11-04 without a device of Latchkey's own (Toni). The first
design (0.8.101 to 0.8.114) linked Latchkey as its own WhatsApp device: it sent text, a photo and
a file live, then its first history sync paused, it dropped after two app installs, and WhatsApp
logged out every linked device of Toni's account (his phone stayed logged in), most likely
because of two days of link codes and test devices on his number (research.md). Now three
tools: `whatsapp_find` and `whatsapp_read` read WhatsApp for Mac's database while that app runs,
else the Owner's WhatsApp Web tab in Safari, else the database marked out of date;
`whatsapp_send` sends only through WhatsApp Web in Safari (people and groups, text, photos,
files; never selecting, reloading, or closing the tab), opening it in a background tab when none
is open (Toni: WhatsApp for Mac's window, a fallback for a few hours, worked only unlocked and was
removed). The old device's stored data is deleted
at the first start. Checked live through the hosted relay on 2026-11-04 (0.8.116, 0.8.117): a
send through the Safari tab (read within seconds), reading by number (WhatsApp for Mac now files
most person chats by privacy id; the address book maps them), and a send through WhatsApp for Mac
with the tab closed; and on 2026-11-05 (0.8.119) sends with the Mac locked and no tab open:
Latchkey opened the tab and the message went out (twice, 14:15 and 21:59 local).

Calls cut off by the app stopping (bug report follow-up 2026-11-03; spec 001 FR-666 to FR-668,
plan D27): built on a branch, not yet installed. A quit records every call still running as cut
off by the quit; a crash or forced quit leaves a sealed mark per running call that the next start
records as ended by the app stopping; the audit check names a call an older app's quit cut off
apart ("1 call not on the Mac because Latchkey quit during it, before it recorded such calls")
instead of as missing, so `call_KBYG…` stops failing installs, without writing anything into
the log for it. No relay change. Unit tests pass (8 new); whether the old quit falls in the
call's window is first seen at the next install.

Latchkey's log for Claude (Toni, 2026-11-03; spec 001 FR-662 to FR-665, plan D26): a new
read-only tool, `latchkey_log`, gives Claude the Mac app's own recent log lines (default 200, up
to 1000, optionally one kind such as connection or permissions), so Claude can find out why
something in Latchkey isn't working. Only the app's events that macOS's log has in public; never
Claude's calls, the relay's address, or file names. Offered whatever the capabilities' levels.
Lines come from the activity log, so they survive restarts, but only events recorded from this
version on (older ones can't be told apart). Installed in 0.8.104 and checked live.
The relay needs no change. Linux servers offer it too (below).

Latchkey's log on Linux servers (Toni, 2026-11-03, "fix everything, properly"; spec 010 FR-1052
to FR-1056, plan D15): servers now offer `latchkey_log` with the Mac's arguments and answer,
always, refused while paused. Lines come from the server's own activity log, where each event
now carries a kind and the words Claude may see (the systemd journal was weighed and rejected:
free text with the relay's address, and readable by the Owner only with persistent storage;
research.md). Kept from Claude: the relay's address ("Connected as …"), call IDs, raw errors
(described by kind, else only the error's type, never its message; security review); new events say why a server
disconnects or won't connect, pause and resume, and failed update checks. Tests, lint, the
Debian container tests, and the end-to-end check (a real MCP client reading the server's log)
pass. Not yet shipped: bump `linux/VERSION`, release, and a live call on a paired server.

Browser reaches the Owner's tabs (Toni, 2026-11-03: "Claude needs to be able to access my tabs
and windows just like its own"; spec 005 FR-424 to FR-431, plan D8): `browser_read tabs` lists
every tab of every Safari window (title, address, window, which is in front, Claude's own),
each named like `4213.2`; `browser_read tab` (or `browser_act tab`) makes Claude work in that tab,
in the background, for reading, back, pictures, clicks, typing, scripts, and closing, under the
same checks and click rules as its own tab, until it opens a url (always in its own tab) or
picks another. While locked, Claude's own page stays in Latchkey's own browser and the Owner's
tabs are tried through Safari. Unit tests and the real Safari check pass (the check also read
one of Toni's tabs, reading only); installed in 0.8.106 and checked through the hosted relay
while locked: listed Toni's three tabs and read one, nothing brought forward.

Releases, terms and privacy, and the directory listing are much later (Toni, 2026-10-22).

Add Latchkey to Claude (Toni, 2026-11-01; spec 001 FR-627, FR-628, FR-659, FR-660, spec 009
FR-915, plan D25): an Add to Claude button opens Claude's add-connector dialog with Latchkey and
the relay's address filled in (claude.ai's documented install link; the Owner still clicks Add,
Add, Connect, signs in, and clicks Allow), next to written steps and the way by hand. It is the
setup window's fifth step, done only once Claude on the web, desktop, and phone has access, and
until then it keeps the menu bar icon's mark (and opens setup at start when known in time); the
Settings window's Claude Apps tab offers it too. The relay's account page starts with it until
Claude has access, and the relay guide ends by opening it. Claude's menu is Customize →
Connectors (Settings → Connectors in older docs, fixed everywhere). Not yet seen: the dialog
itself, which needs a signed-in claude.ai (a signed-out visit keeps the link through sign-in).
Five confused-user reviews (agents playing a non-technical Owner: README, detail page, setup
window, account page, the relay guide as heard and as followed) in two rounds; their fixes are
in: the README starts with the app and Claude Code (no relay first), the guide quotes the link
for `open`, copies the address for the person, names the real menu items, and checks the step's
checkmark, and the app and page number the steps and say what each Add and passkey is.
Google's free trial: Google stops what was made during a trial at day 90 unless the account
was upgraded (Google's docs); the guide tells the Owner so, without making them upgrade (Toni).
Fixed 2026-11-07: relay `hub` TestToolsAreStoredOnlyWhenTheyChange was flaky because it counted
"tools changed" notices as soon as the Mac showed online, a moment before the connect's own
notice; it now counts from after that notice (proven by delaying the notice: the old test then
fails every time, the new one passes).

The Latchkey plugin (spec 011) was built and shipped on 2026-11-01, then withdrawn the same day
(Toni): it didn't help anyone get started and made no difference once Latchkey was connected.
The plugin and its catalog are deleted; the relay guide is back at docs/setup-with-claude.md.
Toni removed the plugin and the `tonimelisma/latchkey` marketplace from his Claude account.

Every use case in every screen state (Toni, 2026-11-01: "half of Latchkey doesn't work with the
lid closed"). `macos/scripts/state-check/` lists 98 use cases (`cases.json`) and tries them all
through the hosted relay with real Claude Code in the state the Mac is in; results go to
`docs/use-cases.md`. First runs, lid open and lid closed, found: Messages couldn't send to any
existing conversation (the database now files them as `any;-;…`, which Messages' scripting
doesn't know; fixed in 0.8.64, checked live); Mail refused to write with the display off
although its window works with the lid closed while unlocked (checked live with
`macos/scripts/mail-check.sh`: sent, with a file, and a draft; since 0.8.65 only the lock stops
it, with a plain answer); Mail refused a recipient shown by the account's full name (fixed in
0.8.64); a Safari click to another site lost Claude's tab (since 0.8.66 the clicked link's
address counts on any site when the page didn't change it in the click; checked with the
stand-in Safari, not yet in real Safari).
With the lid closed and keep-awake on, macOS keeps drawing the built-in screen and the session
unlocked for a few minutes after the last activity (Latchkey's own screen calls count as
activity), then the display goes and the session locks (seen at 22:23, 6 minutes after the last
screenshot). Lid closed and locked (check run, app 0.8.65): Mail's window can't be used,
computer control and screenshots refuse, Safari stops answering scripts after a page; the rest
works. Since 0.8.66 (spec 001 FR-038, FR-039) Latchkey keeps the session as it was behind a
closed lid (a public display-sleep assertion, the lid, monitors, and lock read every second)
and locks the Mac the moment the lid opens; not yet seen live, since the Mac was already locked
when it was installed. Since 0.8.67 Notes can create folders, move notes, and rename notes
(spec 002 FR-154; checked live, lid closed and locked). Since 0.8.68 a Safari script that
times out while the Mac is locked says so (checked live). 0.8.70: Mail answers a message with an
identical copy in another mailbox (2% of a month's mail was blocked). 0.8.71: a PDF without text
is shown as a page picture (checked live). 0.8.72: Claude can close its own Safari page
(spec 005 FR-419).
2026-11-02 (Toni: "we're not circumventing security"): the closed-lid hold is gone (0.8.73) and a
sleeping display is no longer woken; Latchkey never holds off the idle lock (spec 001 FR-661).
Instead, while locked: the browser tools use Latchkey's own WebKit browser with a memory-only,
SameSite=Lax copy of Safari's cookies (0.8.75 to 0.8.78; checked live locked: open, read, link
to another site, back, scripts, picture, signed in to GitHub), and email can be queued with
`mail_queue` and goes out at the next unlock (queued live; the send at unlock not yet seen).
Computer control and screen pictures stay unavailable while locked (tested: macOS draws nothing).
Every alternative tried while locked, what takes focus while the Owner works, and what other
tools do: `docs/screen-states.md` (2026-11-02). Since 0.8.79/0.8.80 the locked browser answers
page dialogs (capped, labelled), follows only Claude's own pop-ups, and identifies as Safari
(signed in to Google and GitHub, checked live); since 0.8.81 finding and reading mail work while
Mail is frozen. Mail froze on 2026-11-02 when a scripted send was tried while locked (a modal
alert behind the lock screen); it stayed frozen after unlock, so the first queued email failed
at unlock and the queue dropped it (the notification showed the raw answer). Mail was quit and
reopened at 19:33. Since 0.8.82 (spec 008 FR-838) a try that sent nothing keeps the email
queued (again in five minutes and at the next unlock, three tries), and the notification is
plain sentences; 0.8.83 (security review): a failure after Send was pressed says Mail may have
sent it and is never tried again. `state-check.sh run` now records what took focus, raised a window, moved the
pointer, or used the clipboard (`focus-watch.swift`, `focus.log` per state, each group's times).
Unlocked run on 0.8.83 (2026-11-02 19:49, one group at a time): 101 of 103 work; a forward to
the Owner's own address was refused because Mail took over 4 s to name the accounts and the
list from Mail's files has no full names (fixed in 0.8.84: sending asks Mail with its usual
wait, and when Mail doesn't answer the last list it gave is used); calendar repeat again
inconclusive: the repeat is set (read back live), but the change answer didn't say so; since 0.8.85 creating and changing an event say how it repeats. Only Mail put windows on top and used the clipboard; Safari (tab mode, Safari
behind) didn't come forward. The three groups (gets in the way, background, works locked) and the experiments for moving the first into the second are in `docs/screen-states.md`; `docs/use-cases.md` now has the unlocked run on 0.8.83 and the lid-closed-locked run on 0.8.78 (the older lid-closed column, app 0.8.62, wasn't kept). Test leftovers (2026-11-02, Toni: "this is production data"): ten Notes folders, a contact card
and group, and test emails had piled up; all removed and checked in each app's own data. Notes
doesn't save the deletion of a folder that still holds notes (it comes back after Notes
restarts); since 0.8.89 Latchkey deletes the notes first and says "deleted" only once Notes'
database agrees, and every `state-check.sh run` ends with a "Nothing left behind" group that
finds and removes anything with the run's tag. Toni chose (2026-11-02) to move all four "gets in the way" items to the background: shell open behind (0.8.86), Safari pictures only while hidden (0.8.90, spec 005 FR-423), Mail without coming forward at all (0.8.96, spec 008 FR-840: the message made, given files, sent, or saved by Mail's scripting, its text typed with Mail behind; 0.8.91 had short moments in front), computer control per app (0.8.93, spec 006 FR-510: computer_look and computer_act take app; press, type, and key go to that app alone, its window pictured while covered).
Mail's alert "could not be moved to the mailbox <the Owner's account> … Invalid base64 string for MIME
content" (after `mail-check.sh send` with a file at 22:12 PT on 2026-11-01, lid closed) came from
Mail saving its own sent copy to Exchange after the message was delivered; Latchkey never writes
MIME, and both copies (ids 104292, 104293) are well formed (Mail's own copy has the file as plain
7-bit text, which Mail had rewritten before the upload; Exchange's has valid base64). Repeated
2026-11-02 20:48 unlocked: the same file through Latchkey and through Mail's own scripting both
saved their sent copy, no alert, so it shows up only with Mail's later upload (lid closed); it
can't be repeated without closing the lid. Since 0.8.87 (spec 008 FR-839, plan D11), when Mail
doesn't answer, Latchkey looks for Mail's alert: an alert window whose one control is its
default button (like this one; 0.8.88 after a security review) is pressed, Claude is told to try again and the Owner gets a notification; any other is named,
with its buttons, for someone at the Mac. Not seen live yet (needs Mail to show such an alert).
2026-11-03: a send started seconds before the Mac locked froze Mail (its compose engine waits
for a window it can't draw behind the lock) until Mail was restarted; since 0.8.100 the lock is
checked again right before making, sending, or saving the message. `screen-state.swift` now calls
a locked Mac with its display asleep "locked", not "screen asleep". Locked run on 0.8.100 (lid open, display asleep, 2026-11-03): all 89 cases outside Mail and computer control work, and the closing sweep found nothing left behind.
A reply or forward with files still brings Mail forward for the paste (under a second): tried
2026-11-03, attaching by Mail's scripting erases a reply's quoted original, so it stays a paste.
Lid closed and still unlocked (2026-11-03 21:08, app 0.8.103): 107 of 108 work, the other
refused plainly (an attachment Mail hadn't downloaded); Mail never came forward; the sweep left
four test emails unread in Deleted Items, so it now marks every one read too.
The display asleep on an unlocked Mac is no longer a state of its own: it lasts only the minutes
before the screen lock and never came up in a day of waiting (Toni dropped it, 2026-11-04), so
the table is complete with four states. A click to another site in real Safari keeps
Claude's tab, and back returns (checked live through Latchkey on 0.8.100, 2026-11-03;
`safari-check.sh` itself would ask the Owner to let the terminal control Safari). The full suite's web-page and shell timing tests fail while
the Mac is under heavy load and pass run alone.

README rewritten as a short product page (Toni, 2026-11-01): the promise, a drawing of a phone
chat (docs/images/phone-chat.svg), five steps (get a relay, sign up, macOS's permissions, add
to Claude, ask), what you can ask, how you stay in charge, links.
The details moved to docs/how-it-works.md and docs/development.md. Until the first release it asks
people to watch the repository for releases; the journey it describes (download, Touch ID
account, add to Claude) needs the notarized download. Nobody else signs up on Toni's relay
(Toni, 2026-11-01): everyone sets up their own with Claude Code.

Several machines and Linux servers (spec 010; Toni asked on 2026-10-31 for plan and build in one
go). Built 2026-11-01: one account pairs any number of Macs and headless Linux servers behind the
one connector; a tool both kinds offer is one tool with "On a Mac" / "On a Linux server" parts
and a `machine` argument; the relay's `machines` tool lists the machines; every answer names the
machine and the others. The Linux program (`linux/`, Go) gives Shell and Files, runs under systemd
as the Owner, pairs with a code typed on the relay's `/link` page, stops what commands leave
running (sudo's too) through delegated control groups, never waits for a sudo password, installs
with one line and updates itself from releases signed with Latchkey's Ed25519 key. The Mac app
(0.8.61) sends its name and kind and has "Name shown to Claude" in Settings. Tested: relay and
Linux unit tests; every Linux test on Debian 12 with systemd in Docker; the end-to-end check
(private relay, pretend Mac, the program installed with install.sh in a container, a real MCP
client, and real Claude Code running a command on the server). Eight security review findings
fixed while building (research.md). Mac tests: everything this change touches passes; page-script,
shell-job, and leftovers tests time out on this Mac today, and fail the same way on unchanged
main (macOS isn't reporting process ends or loading test pages; looks like this Mac's state, not
the code; rerun after a restart). Shipping: see the next item.

Spec 010 shipped 2026-11-01: relay deployed (d242688); `server-v0.1.0` published on GitHub
(Intel and Arm, signed); app 0.8.61 installed (paired, keep-awake on, helper running, all 689
calls match the relay's audit). Live check through the hosted relay with a fresh Claude Code
session: `machines` lists Toni's Mac, and `shell_run` without a machine name ran on it and ended
with the Mac's state line. On Toni's Google VM (Ubuntu 24.04, Intel) the install line from GitHub
downloaded the release, checked it, and showed a pairing code; it was not approved and the
unfinished install was removed (nothing is left on the VM; it can be paired the same way any
time).

Toni's home server purkki (Ubuntu 26.10, Intel, passwordless sudo) paired 2026-11-01 with the
install line and the code typed on `/link`; its service runs. Live check through the hosted relay
with a fresh Claude Code session: `machines` lists the Mac and purkki, both online; on purkki
`uname`, `uptime`, and `sudo -n whoami` (root) ran, and nothing was left running; a command without
a machine name was refused with both machines listed.

Relay web pages redone 2026-11-01 (spec 001 FR-650 to FR-658), after Toni found the account page's
top cut off and the code field misdrawn: pages center with auto margins and can always be scrolled
to the top; the account page has Machines, Add a machine (the Linux install line and the connector
address with copy buttons), Claude, Recent activity (last 10), and Account; the activity page lists
tool calls and the Owner's account events together, 50 at a time; connecting a machine lands on the
account page with the machine named and marked; times in the viewer's time zone. The browser test
checks every page at 320, 375, and 1280 px. Then two visual reviews (Claude's and an independent reviewer's, from screenshots of every page) led to contrast fixes, distinct success/warning/error messages, confirmations before removing, Cancel on approval pages, day headings in the activity, and honest status for a just-connected machine (research.md). There is no Mac app download yet, so Add a machine
links to the README's Get started.
Open (later, for Toni): service, container, package, process, and network tools for servers
(left out of this spec); a direct machine-to-machine file copy; distributions whose sudo uses
pam_systemd are unverified for stopping sudo's leftovers.

Easy relay setup (Toni, 2026-10-31; to become its own spec, 009): a person with no technical
background but a Claude subscription gets their own relay. Decided: Claude Code sets it up and
guides them, on free hosting where possible (Google Cloud, AWS, or similar); a personal relay
needs no email server (the first sign-up enters a setup code; email stays optional for shared
relays); relay images on ghcr.io; Apple's Developer Program (signed, notarized app that updates
itself) later. Research so far (one-click hosts compared: Railway, Render, Fly.io; passkeys work
on platform addresses on the Public Suffix List; moving to a custom domain later invalidates
passkeys) and the free-cloud research are in specs/009-easy-relay-setup/research.md. Toni added: one path
that works end to end with minimal hassle for non-technical people, and everything customizable
for technical ones (own VPS, domain, Railway, email server); Podman runs and updates the relay
on a server. Spec 009 and the guide Claude Code follows (docs/setup-with-claude.md) are drafted
for Toni's review. Default host: Google Cloud's free server (Toni, 2026-10-31). Lost passkeys are
replaced through Claude Code with a one-time recovery code (Toni). The repository is public
(2026-10-31). Plan and tasks written
(specs/009-easy-relay-setup/plan.md, tasks.md). Built (0.8.60, 2026-10-31): the relay's setup
code (no email server needed), the operator's recovery-code command, the ready signal for
Podman's update rollback, a database copy before migrations, the deploy publishing images for
Intel and Arm servers, the self-hosting docs, and the app's "Copy Request" for Claude Code in
setup; the session cookie was already host-bound. Tested: unit tests, and real Chrome claiming a
relay with its setup code and recovering with the operator's code. Toni granted image publishing
and made the image public (2026-10-31); the relay is deployed and `ghcr.io/tonimelisma/latchkey-relay`
has `latest` for Intel and Arm. The guide ran for real (T9, `relay/cmd/guidecheck`) in a throwaway
Google Cloud project: the relay answered with a Let's Encrypt certificate for its sslip.io name
about 3 minutes after the server was created; claimed with its setup code in headless Chrome, a
pretend Mac paired, Claude Code read the battery through it; sign-up then closed; the guide's
recovery command and code worked; Podman's updater installed a new image and rolled back a broken
one by itself. The project and its budget alert were deleted. Found and fixed in the guide:
Compute Engine needs a minute after it is turned on, the first start takes about 3 minutes, and
`gcloud compute ssh` needs `--quiet`. Still to check on a fresh Google account: whether the free
server's address costs nothing, and whether the trial must be upgraded. The test's nine image
versions (tag `guidetest`) were deleted with Toni's OK (the GitHub CLI now also has
`delete:packages`); the registry holds only real releases. Open: checking on a fresh Google
account that the free server's address costs nothing and whether the trial must be upgraded.

Nothing left behind (Toni, 2026-10-27; app 0.8.32): after headless Chrome ran two days and
`/tmp` filled with a session's downloads, a Shell command's leftovers are stopped when it
finishes (its terminal session, its family followed every half second, and programs using its
scratch folder) unless Claude asks to keep them (`keep_minutes`, renewed by checking, 24 hours
at most); each command has a scratch folder (`TMPDIR`) moved to the Trash afterwards; writes
outside scratch, the command's folder, Downloads, package caches, and declared `writes` fail
(macOS's sandbox), shell startup files, launch agents, login items, `~/.ssh`, and git hooks only when declared; what
is left goes to Claude in the answer and to the Activity window's Left Behind view; Toni is
notified only of undeclared changes to launch agents, login items, or startup files and of
processes that won't stop. Also: Notes deletes folders; Messages copies go once sent; Claude's
Safari window closes after 30 minutes unused; things made through the tools are on the list.
Specs 004 FR-313 to FR-326, 001 FR-640 to FR-643, 002 FR-152 and FR-153, 005 FR-411. A scratch
shell in a throwaway Linux container was left out. The gaps are closed since app 0.8.39
(Toni, 2026-10-28; spec 004 FR-327 to FR-329): a quick double fork is found by a mark its fence
carries; opening apps, files, or links (`open`) and scripting other apps (`osascript`) need
`uses`; changing settings (`defaults write`) needs the domain's file in `~/Library/Preferences` in `writes` (never Latchkey's own); launchd
already refused jobs from inside the fence. Same release (spec 007 FR-713, FR-723): Reminders
deletes a list when Claude gives how many reminders it holds; Contacts creates, renames, and
deletes groups and adds or removes cards. Checked live on 2026-10-29 through the hosted relay
with a fresh Claude Code session: `open -a` and `osascript` refused with the hint, a script
declared with `app_scripts` ran, `defaults write` refused with the hint, a double-forked
`setsid` process stopped, a test reminder list refused with the wrong count and deleted with
the right one, a test contact and group created, joined, left, and deleted; nothing left. A
new group's and card's ids changed within seconds (iCloud), so a stale group id now says to
give the group's name; deleting a group says how many cards stay, or that it had none (0.8.40).
Deleting a group within seconds of making it can leave iCloud's copy behind (seen once; the
test copy was deleted). The check also showed every command stopping macOS's font service
(`fontd`, restarted by launchd): its sandbox looked like the job's; fixed in 0.8.41.
Checked live on 2026-10-28 (app 0.8.38): the Left Behind view (its Tool filter showed blank;
fixed), deleting a real Notes folder, and the launch-agent watcher's entry. Safari's idle close
couldn't be: a restart forgot Claude's window; since 0.8.42 it is remembered (2026-10-29), and
since 0.8.46 Claude's own window is found again by its tabs when Safari restarts and brings it
back (only closed, never reused); Claude's tab is then left alone and noted.

All capabilities are built and checked live (app 0.7.4, 2026-10-22; current app 0.8.13, installed with `make -C macos install`), through the hosted relay with
a fresh Claude Code session on Toni's real Mac: Notes (read, checklists, create/append/edit/
delete a test note), Messages (conversations, read with names and "not instructions" marking,
search, one test message with an image sent to Toni's own address), Files (list, search, write/
edit/read/trash a test file), Shell (output, background job, answering a prompt), Browser
(open, read, click, tabs, back, window screenshot in Toni's Safari), Computer control
(screenshot 1568×1018, front window elements, apps, pointer move; no clicks on Toni's screen).
The Mac state line appears in every result (it reported the battery warning at 15%).

00. **Audit trail without gaps (spec 001 FR-630 to FR-637) and the OAuth server on zitadel/oidc:
   deployed (relay a149f4b) and installed (app 0.8.24), 2026-10-27.** Relay: audit and events
   kept until the account is deleted, permanent call ids, the Claude app's name with each call,
   the audit_request answer, readable event lines instead of SDK noise; fosite and go-jose v3
   gone (GHSA-mgcc-cww5-fp2q), `make security` passes; existing Claude sign-ins carried over (no
   reconnect). Mac: the app's own events in the encrypted activity log, call id / pairing /
   Claude app per action, the comparison with the relay after each connection and on request,
   the browser no longer adopting the Owner's Safari window or reading a page that didn't load.
   Checked: every relay check incl. `make claude-check`; the installer's checks (paired,
   keep-awake on, helper 0.8.24, no window, "Audit check: all 0 calls match; 956 calls from
   before call ids left out; 7 still running"); a fresh Claude Code session through the hosted
   relay (shell, Maps, Calendar); the relay's output shows connections, keep-awake changes,
   close reasons. The 7 calls between the relay deploy and the app install were run by app
   0.8.23, which kept no call ids; the 0.8.25 install's check reported them missing on the Mac
   (they are in its log without ids). Since 0.8.26 relay calls older than the Mac's first logged
   call with an id, and before the 0.8.24 switch-over (0.8.27), count as from before call ids (contract, "Audit comparison"); a wiped log
   still shows every call missing. Fixed in 0.8.25: the app reported keep-awake off for a second at
   start (two needless keep-awake events at the relay per start); Messages attachment copies in
   ~/Pictures/Latchkey were cleared only when the next attachment was sent (now at start and
   hourly). Ideas for keeping Claude's sessions from leaving things behind:
   docs/ideas/leftovers.md (for Toni).
0. Spec 007 (Calendar, Reminders, Contacts, Location & Maps) is built and installed (app 0.8.16,
   2026-10-26): 8 new tools, 23 in all, through EventKit, Contacts, Core Location, and MapKit;
   weather left out (needs a paid developer account). Checked live through the hosted relay: all
   23 tools listed; Calendar, Reminders, and Location answer at once with what to allow; a
   coffee search near Walnut Creek and the Contacts overview (280 contacts) worked; directions
   to a place by name failed in 0.8.15 (Apple's geocoder takes addresses only) and now fall back
   to a place search (0.8.16).
   After Toni allowed Calendars, Reminders, and Location (app 0.8.18), a fresh Claude Code
   session through the hosted relay: listed 8 calendars and found free time; created, moved
   (length kept), and deleted a test event with an alert; created, completed, and deleted a test
   reminder; created, found by phone digits, and deleted a test contact; read the Mac's address
   (about 40 m). Nothing was left behind. The new contact's id changed within seconds (iCloud
   sync, apparently), so the first delete answered "search again" and the second worked.
   Open for Toni's review: deleting reminder lists and changing contact groups are not offered
   (research.md). Keep-awake was off: the helper started 2026-10-25 kept running across later
   installs, re-read its own replaced file for the signature check (UNIX error 2), and refused
   every app connection. Fixed in 0.8.19 (read once at start; ends itself when replaced; the app
   retries); Toni restarted the old helper (launchctl kickstart, 2026-10-27); SleepDisabled is 1 again. Since 0.8.20 (FR-620) the keep-awake decision, the helper, the connection, sleep and wake, and permissions are in macOS's log (plan D16). The
   state line's "not approved in System Settings" also covers a helper that doesn't answer; Calendars'
   Allow… showed nothing in 0.8.16 (Toni then allowed both in System Settings; since 0.8.17 the
   button logs macOS's answer and opens System Settings when no question appears).
   The activity log kept forever (item 12) is on main and installed with app 0.8.18.
1. Toni reviews specs 003–006 (built without review stops, at Toni's request).
2. When the repository goes public: turn on GitHub private vulnerability reporting
   (`gh api -X PUT repos/<owner>/latchkey/private-vulnerability-reporting`), which SECURITY.md
   points to. GitHub offers it only for public repositories.
3. ~~Dependency scanning~~: done 2026-10-23 with the rest of the hardening (abuse limits,
   headers, container, `make security` gating deploys, CI, Dependabot, pinning; see
   docs/best-practices.md §4 and §7). Watch the first CI run and Dependabot's first proposals.
4. ~~End-to-end encryption between Claude and the Mac~~: closed 2026-10-29 (Toni): not
   possible, since Claude's custom connectors send plain bearer-token requests with no inner
   layer to encrypt or sign (research in docs/best-practices.md §4). Not pursued.
5. ~~Whole-repository security scan~~: done 2026-10-24. Threat model (docs/threat-model.md),
   then Anthropic's Claude Security scan twice at high effort: 57 findings (none critical or
   high) that merge into about 25 issues, each fixed with a failing test first (app 0.8.6).
   Semgrep (with Latchkey's own rules), ShellCheck, OSV-Scanner, and a Sparkle advisory check
   now gate every deploy. Choices Toni made are in docs/decisions.md (2026-10-24).
   Toni decided (2026-10-24): `golang.org/x/net` stays a direct relay dependency; the pairing
   and the activity log's key move to the app-only keychain together with notarized releases
   (until then another program gets a macOS prompt, not a hard refusal).
   Live check passed 2026-10-24 after Toni paired again: a fresh Claude Code session through the
   hosted relay saw all 15 tools and the Mac state line, Browser refused `javascript:` and
   `file:` with the http/https message, and Files listed the home folder. On the Mac, the old
   activity log file is gone and the new one is updated and holds no readable text.
6. ~~Second security review~~: done 2026-10-25. Six reviewers, one per trust boundary, checked
   against the MCP security pages, RFC 9700 and OWASP's MCP Top 10: nothing critical or high
   open, no path between accounts. About 40 medium and low issues fixed test-first in the relay,
   the app and the deploy scripts (docs/decisions.md, 2026-10-25). Toni decided: the Allow page
   every time; turning a capability down stops its running work; emailed codes and the daily
   lock stay as they are (accepted risks in docs/threat-model.md).
   The install then showed a bug from 0.8.4: the app's Keychain read always failed, so any
   restart came up unpaired and replaced the activity log's key (the log before 2026-10-24
   21:31 can no longer be read). Fixed in 0.8.8; the existing pairing was picked up again.
   Live check passed 2026-10-24 21:36: a fresh Claude Code session through the hosted relay saw
   15 tools, ran a shell command, was refused a change to Latchkey's own settings file, wrote,
   read and trashed a test file; keep-awake stayed on. DNS shows the reject mail policy and the
   two certificate authorities.
   Not checked live (need Toni at the Mac or a fresh sign-in): the Allow page and the issuer
   parameter with claude.ai (passed with real Claude Code against a private relay), Shell
   switched off while a command runs, a page with a filled password field.
   Decided and done 2026-10-25: a nightly copy of the server's disk, kept 14 days
   (`deploy/backup-schedule.sh`); the full-access email key removed from `.env`; Debug and test
   builds get their own app identity (app 0.8.9, installed, still paired, live call answered).
7. ~~Four ideas from the research~~: built and shipped 2026-10-25 (spec 001 FR-180 to FR-199).
   Only Claude's apps may ask for access (clients on `claude.ai`; open registration is off).
   The relay's signing keys are encrypted under a key file kept outside the database's folder.
   The Mac's menu and the account page list the Claude apps with access, each removable.
   The relay publishes terms and a privacy policy (operator details from settings) and has
   operator commands to list, suspend, and delete accounts and to block addresses.
   Checked live after the deploy: registration answers 403 and is no longer advertised; the
   terms and privacy pages show the operator, the contact address, California law, and 14-day
   backups; the key file was created (mode 600) and the pre-conversion database copy removed;
   no stored client was removed, so the existing Claude connection kept working; `account list`
   runs on the server; app 0.8.10 started paired, a fresh Claude Code session ran a command, and
   the menu shows "Claude Apps With Access" with the existing approval and its Remove.
   Not checked live: removing an app from the menu or the page (it would cut the working
   connection), suspending an account (needs a throwaway account with a passkey), the Allow
   page from claude.ai. All three are covered by tests against a real relay.
   Open for Toni: have the terms and privacy policy read by a lawyer before sign-up opens to
   the public; keep a copy of the server's key file somewhere apart from the server; the
   choices listed as Claude's in docs/decisions.md (operator record kept a year, liability
   wording); nightly disk copies from before 2026-10-25 still hold the old keys unencrypted
   until they age out (14 days), `relay reset-keys --confirm` would end that at once at the
   price of signing in and connecting Claude again.
8. ~~Five small fixes~~: done 2026-10-25 (app 0.8.11, spec 001 FR-200 to FR-204). The Mac's
   state line always starts on its own line; the activity log's key is never replaced when it
   merely couldn't be read (and an unreadable pairing is never written over); older entries
   that can't be read no longer show as failed; the installer fails when an update loses the
   pairing; a suspended account's Mac says so and reconnects by itself.
   Checked live: a fresh Claude Code session wrote, read, and trashed a file and ran a command,
   and the state line was on its own line in all four; the installer's new check passed on the
   real install ("paired"); the menu's Recent Activity has no "unknown (failed)" rows.
   Not checked live: the suspended state in the menu (covered by the Mac connection check
   against a private relay), and the Activity window's wording on screen.
9. ~~Leftover helper folders~~: fixed 2026-10-25. A helper agent's working folder stayed on disk
   after its work was merged, because Claude Code keeps it locked while the session runs and the
   tidy script trusted that lock. Tidy now removes such a folder once its commits are on main and
   nothing runs in it, and the end-of-turn check reports any that is still there.
10. ~~Window at every start~~: fixed 2026-10-25 (app 0.8.12, FR-205). The setup window opened
   on every start although everything was set up, because the app checked "connected to an
   account" a moment before its connection had reported in. A stored pairing now counts from
   the first moment.
11. ~~Menu redesign~~: done 2026-10-26 (app 0.8.13, spec 001 FR-600 to FR-605, spec 002
   FR-131; checked against Apple's guidelines). The menu bar key shows by shape whether Claude can
   reach the Mac (a line through it when not) and marks paused, setup unfinished, and working.
   The menu is short: status, Keep Mac Awake, Pause Claude's Access, the newest five activities
   (naming the command or file), Show All Activity…, Settings…, Quit. Capability levels, the
   macOS permissions (each with its state and an Allow button, app 0.8.14), Claude apps with
   access, the relay and Disconnect (now confirmed first), and Start at Login are in a Settings
   window. The battery line is gone.
12. ~~Activity log kept for good~~: built 2026-10-26 (spec 001 FR-026,
   FR-610 to FR-615), installed with app 0.8.18. Nothing is deleted
   by age; the Activity window shows the log's size, warns when entries were removed, changed,
   or cut off the end (a keyed checksum chain plus a Keychain record of the newest entry), loads
   a page at a time, searches by text, tool, and dates, and exports JSON Lines. Not yet checked
   on Toni's installed app (the upgrade of his existing entries is covered by a test).
2. Known limit: macOS shows its own "allow Latchkey to access the screen directly" alert from
   time to time for screen capture; it needs Toni at the Mac (computer control only).

Browser (Toni, 2026-10-29; spec 005 FR-412 to FR-418; app 0.8.44): Claude's pages open in a
background tab at the end of Toni's front Safari window; Settings → What Claude Can Do →
Browser → "Claude Opens Pages In" switches to a window of its own. A screenshot brings
Claude's tab forward and Toni's back; idle close closes the tab. Claude's tab is known by a
hidden mark on its page and checked again inside every script that acts on it, so a tab of
Toni's is never read, loaded, closed, or brought forward (security review). A tab Latchkey
can't be sure of is left open and named in Left Behind.
Since 0.8.45 a page's own note of where it is going counts only for its own site and can't keep
the loading allowance open (security review): a click to another site loses Claude's tab, which
stays open, is named in Left Behind, and Claude's next page opens in a fresh tab.
Activity window (spec 001 FR-616; app 0.8.44): opens at once however big the log grows; the
tamper check grows in a straight line instead of with the square of the log and runs in the
background ("Checking…" until done); a start no longer reads the whole log on the main thread.
Two once-flaky tests made steady (best of three timings; counted waits instead of sleeping).
Contacts (spec 007 FR-724 to FR-727; app 0.8.44): cards and groups Latchkey made are found
again when iCloud gives them a new id, and iCloud's copy is deleted with them within 10
minutes; Toni's own look-alikes are never matched; every such deletion is notified.
Tests (Toni, 2026-10-29; app 0.8.45): a full `make test` takes about 32 s with the build,
down from about 2.5 min, and the random hang is gone. The suites now run side by side; the hang
was the Shell self-check blocking a shared thread while waiting for its test program to end
(also a possible stall at the app's start); stopping a command right after starting it took
3 s because Ctrl-C was sent before its shell existed (now waits for the shell); the large-log
test uses 30,000 entries; waits on processes, output, and file events look again for up to 5 s
instead of a fixed time.
Since 0.8.45 Shell never scripts other apps (Toni, 2026-10-29): `osascript` is always refused,
since a script reaching an app must run outside the fence and could run anything.
Declared app scripts (`uses: ["app_scripts"]`) never reached an app from 0.8.39 to 0.8.43:
apps refuse Apple events from any sandboxed program; since 0.8.44 `osascript` runs outside the
fence when declared (found by the Mail research).
Shell self-check (Toni, 2026-10-29; app 0.8.43; spec 004 FR-330): at start, Latchkey checks
that the fence still refuses a write and that a program in a fence is found by its mark; when
a macOS update breaks either, commands still run, every Shell answer says so, and Toni gets
one notification. Specs 003 to 006 reviewed and approved by Toni (2026-10-29); spec 005 gets
Claude's tab in Toni's own Safari window as the default (in progress).

Browser in the real Safari (app 0.8.48, 2026-10-30): a same-site click, typing, or back keeps
Claude's tab (the page's note is read in the script's own run; the clicked link's and back's
address count; a short wait for late notes); long pages come in parts within Claude's result
size, the answer naming the offset to read on from; page positions are bounded and the tab's
token is spliced as a JSON literal (security review). Checked in the real Safari with
`macos/scripts/safari-check.sh` (a window of its own; all checks pass). A script that sends
the page elsewhere, or a click to another site, still loses the tab by design.
Relay: dependency updates (chromedp/cdproto, x/net, modernc sqlite) and a test of the
fosite carry-over that froze a time the MCP SDK checks against the real clock.
Mail (spec 008, approved by Toni; app 0.8.49): `mail_find`, `mail_read`, `mail_change`,
`mail_send`, 27 tools in all. Finding and reading come from Mail's own database (read-only)
and message files (MimeFoundation), so they work with the screen off; reading never marks a
message read unless Claude asks. Organising goes through Mail's scripting; delete moves to the
account's Trash. Sending and drafts are written in Mail's own compose window through
Accessibility (Toni, 2026-10-30: Mail's scripting makes the text arrive indented as a quote in
other mail apps, checked live), and are refused while the screen is off or locked. Security
review: a copied Message-ID is refused and the window compared with the original before typing,
recipients must be exactly as asked, the clipboard is only lent (marked, given back), and
attachment names never become paths. Tested with stand-ins; the live check of the compose
window needs the screen on.
Checked live 2026-10-30 (lid closed): accounts, mailboxes and unread counts found, the newest
unread message read and left unread, and sending refused with the reason (screen off). A
message whose text ended in raw HTML table markup: since 0.8.50 a plain part that is itself
HTML is converted, and HTML comments (Outlook's conditional ones) are dropped first. Since 0.8.51
both in time that grows only with the message (security review).

Live check of sending, 2026-10-31: one test message to Toni's own address went out through
Mail's compose window and was in Sent; its raw copy is plain text (7bit, Mail's own headers),
the two body lines exactly as asked, with no "> " quoting, indentation, or extra content.

Every permission at first run (0.8.52, Toni 2026-10-31, spec 001 FR-623): every approval any
capability can use is asked for at first run, whatever the levels, so macOS never asks during
use. Right after pairing Latchkey asks each macOS question in turn. Since 0.8.53 the setup
window has four steps instead of seventeen (connect, macOS's questions, System Settings,
Safari), and System Settings opens page after page as each switch is turned on.
Three approvals were added: Notifications (asked during use until now), Local Network (asked
when a command reached a device at home), and macOS's direct screen access question (asked at
the first screenshot). Accessibility is now asked for whatever computer control is set to,
since sending mail needs it. Checked live 2026-10-31 after Toni's Allow All: a screenshot,
location, a command reaching the home router, calendars, reminders, contacts, notes, mail,
messages, and a Safari page all worked through the hosted relay, with no macOS question on the
screen and the setup window closed.

macOS's monthly screen question (0.8.54, spec 001 FR-624): macOS 27 still asks about once a
month whether Latchkey may keep seeing the screen, at its first screenshot after a date macOS
keeps (on Toni's Mac: last asked Oct 23, next Nov 22). Once that date has passed and Toni is
using the Mac, Latchkey takes one throwaway screenshot, so the question comes while he is
there. It can't come earlier than macOS's date; Apple's screen-sharing permission (asked for
by application) would remove it, and is not applied for.

Missing permissions named (0.8.55, spec 001 FR-625): an audit of every tool found most
permissions already answered clearly; the gaps now are too. Notes, Messages, Mail, and Safari
don't run a script when macOS hasn't asked about the app yet (that raised the question during
use and timed out after 25 seconds); Full Disk Access taken away later, a file macOS protects,
a Shell command refused by it, Contacts missing for names in Messages, and a refused
screenshot each say which permission and where to turn it on. Checked live 2026-10-31 through
the hosted relay: location, a command reaching the home router, calendars, reminders,
contacts, notes, mail, messages, and a Safari page all worked (Safari's script ran past the new
check); the screenshot couldn't be tried (lid closed), nor the monthly screen question (due
Nov 22). Since 0.8.56 an app that isn't open is opened hidden to be checked first, and a Shell
command that can't reach a device nearby says when Local Network isn't allowed.

A lost permission is told (0.8.57, Toni 2026-10-31, spec 001 FR-626): the app looks every
minute, and after any failed call, at every permission and setting setup asks for. One that was
on and is now off brings one notification ("Full Disk Access is off"), once per loss; a click
opens setup, and the menu bar icon shows its mark until it's back. Not seen live: that needs a
permission turned off in System Settings, which only Toni does. The screenshot was checked live
the same day through the hosted relay (lid open): a clear image of the whole screen.

Offline after a second copy (0.8.58, 2026-10-31, spec 001 FR-206, FR-207): another Claude
Code session on this Mac started Latchkey's program directly at 16:41; that copy ran under its
permissions (setup opened, Full Disk Access and others "missing"), took over the relay
connection, and was quit two minutes later. The real app, told it was replaced, had stopped for
good, so the Mac stayed offline until restarted. Now a second copy quits at once, the app never
stops trying while paired, and the state update that got every start refused once (sent
during the sign-in) waits for the welcome. The permission notice was seen to work in the same
event: Location turned off at 16:43, notification delivered at 16:44:52.

README pictures (0.8.59, 2026-10-31): the README shows the setup window (connect, macOS's
questions) and Settings (What Claude Can Do, Permissions), drawn by the app's own views with
sample data (`macos/scripts/readme-shots.sh`; never this Mac's data or the hosted relay's
address). The menu bar menu isn't pictured: it can't be drawn off-screen, and a real capture
would show real activity.

Shell test fixed (2026-10-31): "a process that left the terminal is stopped too" gave its
program a fixed half second to start, and failed once while the whole suite ran. It now waits
until the program says it has left its session; then passed 40 runs under CPU load and 11 full
suites (704 tests each, before and after), and its checks print what they saw.

## Waiting on Toni

1. Answer the macOS alert about Latchkey accessing the screen (Allow) whenever it shows (none
   showing and none in macOS's log on 2026-10-29).

The other live checks that need Toni (the Allow page from claude.ai, removing an app's access,
Shell switched off mid-command, a page with a filled password field, a suspended account) are
left to the tests against a real relay and real commands (Toni, 2026-10-29).

## Milestones (from `specs/001-core/plan.md`)

| # | Milestone | State |
|---|---|---|
| M1 | Relay hub + agent protocol, Go test agent | Done |
| M2 | OAuth, passkeys, pairing (relay side) | Done |
| M3 | Mac app: pairs, connects, keeps awake, answers `battery_status` | Done (0.1.2) |
| M4 | End to end from Claude on phone, web, Desktop | Desktop done; phone check and time limit left |
| M5 | Signing, notarization, Sparkle, Docker image | Container and hosting done; public download since 2026-11-09 (development-signed, Open Anyway); notarization and Sparkle need a Developer ID |

## Risks

- Lid-closed keep-awake relies on `pmset disablesleep`, which Apple does not document; reports
  conflict on Apple silicon charger changes. Mitigation: re-apply and read back on every power
  change and wake (plan D7). No spike or hardware test runs (Toni, 2026-10-20).

## Open questions

| Question | Resolve by |
|---|---|
| Claude's hosted-client tool-call timeout (undocumented) | Measure in M4; keep our 60 s cap below it |
| Terms, privacy policy, abuse handling for the hosted relay | Launch blocker, deferred |
| The repository must be public for update downloads (GitHub Releases) | Done: public since 2026-10-31; downloads since 2026-11-09 |
