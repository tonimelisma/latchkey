# Status

Last updated: 2026-10-29 (Claude's Safari window or tab after Safari restarts; Shell's start check can't hang; app 0.8.46)

Xcode signing ready (2026-10-20): Toni's Xcode account has a valid "Apple Development" certificate
(certificate expires 2027-07-22). Keep the team ID out of committed project files
(open source); put it in a gitignored `macos/Local.xcconfig` as `DEVELOPMENT_TEAM`.

## Current phase

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

Releases, terms and privacy, and the directory listing are much later (Toni, 2026-10-22).

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
Activity window (spec 001 FR-616; app 0.8.44): opens at once however big the log grows; the
tamper check grows in a straight line instead of with the square of the log and runs in the
background ("Checking…" until done); a start no longer reads the whole log on the main thread.
Two once-flaky tests made steady (best of three timings; counted waits instead of sleeping).
Contacts (spec 007 FR-724 to FR-727; app 0.8.44): cards and groups Latchkey made are found
again when iCloud gives them a new id, and iCloud's copy is deleted with them within 10
minutes; Toni's own look-alikes are never matched; every such deletion is notified.
Declared app scripts (`uses: ["app_scripts"]`) never reached an app from 0.8.39 to 0.8.43:
apps refuse Apple events from any sandboxed program; since 0.8.44 `osascript` runs outside the
fence when declared (found by the Mail research).
Shell self-check (Toni, 2026-10-29; app 0.8.43; spec 004 FR-330): at start, Latchkey checks
that the fence still refuses a write and that a program in a fence is found by its mark; when
a macOS update breaks either, commands still run, every Shell answer says so, and Toni gets
one notification. Specs 003 to 006 reviewed and approved by Toni (2026-10-29); spec 005 gets
Claude's tab in Toni's own Safari window as the default (in progress).

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
| M5 | Signing, notarization, Sparkle, Docker image | Container and hosting done; releases need Developer ID |

## Risks

- Lid-closed keep-awake relies on `pmset disablesleep`, which Apple does not document; reports
  conflict on Apple silicon charger changes. Mitigation: re-apply and read back on every power
  change and wake (plan D7). No spike or hardware test runs (Toni, 2026-10-20).

## Open questions

| Question | Resolve by |
|---|---|
| Claude's hosted-client tool-call timeout (undocumented) | Measure in M4; keep our 60 s cap below it |
| Terms, privacy policy, abuse handling for the hosted relay | Launch blocker, deferred |
| The repository must be public for update downloads (GitHub Releases) | Toni, before the first release |
