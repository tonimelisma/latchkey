# Status

Last updated: 2026-10-24 (whole-repository security scan done; app 0.8.6)

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

All capabilities are built and checked live (app 0.7.4, 2026-10-22; current app 0.8.6, installed with `make -C macos install`), through the hosted relay with
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
