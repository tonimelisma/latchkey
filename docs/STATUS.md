# Status

Last updated: 2026-11-01 (README rewritten as a short product page; Latchkey plugin for Claude, spec 011; relay web pages redone; purkki paired; spec 010 shipped)

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

Latchkey plugin for Claude (spec 011; Toni asked on 2026-11-01 for the spec from a blank slate,
the repository arranged for it, and everything finished without questions). Built 2026-11-01: a
plugin of two skills only, `latchkey` (how Claude works on the machines: no tools, choosing a
machine, offline, refusals, where things run) and `set-up-latchkey` (connecting Claude, pairing a
Mac or a server, the relay guide, fixing a connection), in `plugin/`, published by the catalog
`.claude-plugin/marketplace.json` at the root: people add `tonimelisma/latchkey` on claude.ai
(Customize → Plugins → Add marketplace) or in Claude Code. The relay guide moved from
`docs/setup-with-claude.md` into the setup skill; the Mac app's Copy Request (0.8.62) points
there. The relay's account page and the README say to add the plugin. Checked: content checks
(no capability or tool names, no addresses, nothing that runs, version raised) with their own
tests, Claude Code's validator in strict mode, and evals with real Claude on pretend Latchkey
tools: with the plugin every case passes; it turns "I can't" into the right setup steps (+1.00 on
both setup cases) and changes nothing where the tool descriptions already work (offline, two
machines, refusals). Shipped 2026-11-01: on main, relay deployed, app 0.8.62 installed; a fresh
Claude Code session with the plugin from GitHub's main used the real connector and the setup
skill correctly. Toni added the catalog and the plugin on his claude.ai account (2026-11-01);
Constitution VIII no longer counts projects (Toni). Toni approved all eight choices made for
him (plan.md "Choices made for Toni") in chat on 2026-11-01.

README rewritten as a short product page (Toni, 2026-11-01): the promise, a drawing of a phone
chat (docs/images/phone-chat.svg), five steps (get a relay, sign up, macOS's permissions, add to Claude, ask), what you can ask, how you stay in charge, links.
The details moved to docs/how-it-works.md and docs/development.md. Until the first release it asks
people to watch the repository for releases; the journey it describes (download, Touch ID
account, add to Claude) needs the notarized download and open sign-up on the hosted relay.

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
on a server. Spec 009 and the guide Claude Code follows (docs/setup-with-claude.md, now plugin/skills/set-up-latchkey/own-relay.md) are drafted
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
