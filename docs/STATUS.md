# Status

Last updated: 2026-10-25 (the app starts in the menu bar only when setup is done; app 0.8.12)

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

All capabilities are built and checked live (app 0.7.4, 2026-10-22; current app 0.8.12, installed with `make -C macos install`), through the hosted relay with
a fresh Claude Code session on Toni's real Mac: Notes (read, checklists, create/append/edit/
delete a test note), Messages (conversations, read with names and "not instructions" marking,
search, one test message with an image sent to Toni's own address), Files (list, search, write/
edit/read/trash a test file), Shell (output, background job, answering a prompt), Browser
(open, read, click, tabs, back, window screenshot in Toni's Safari), Computer control
(screenshot 1568×1018, front window elements, apps, pointer move; no clicks on Toni's screen).
The Mac state line appears in every result (it reported the battery warning at 15%).

1. Toni reviews specs 003–006 (built without review stops, at Toni's request).
2. When the repository goes public: turn on GitHub private vulnerability reporting
   (`gh api -X PUT repos/<owner>/latchkey/private-vulnerability-reporting`), which SECURITY.md
   points to. GitHub offers it only for public repositories.
3. ~~Dependency scanning~~: done 2026-10-23 with the rest of the hardening (abuse limits,
   headers, container, `make security` gating deploys, CI, Dependabot, pinning; see
   docs/best-practices.md §4 and §7). Watch the first CI run and Dependabot's first proposals.
4. End-to-end encryption between Claude and the Mac: researched, not decided (options in
   docs/best-practices.md §4).
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
2. Known limit: macOS shows its own "allow Latchkey to access the screen directly" alert from
   time to time for screen capture; it needs Toni at the Mac (computer control only).

## Waiting on Toni

1. Answer the macOS alert about Latchkey accessing the screen (Allow), if it's still showing.

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
