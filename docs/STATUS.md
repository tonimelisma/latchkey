# Status

Last updated: 2026-10-20 (tasks.md written)

Xcode signing ready (2026-10-20): Toni's Xcode account has a valid "Apple Development" certificate
(team ID `TEAMID1234`, expires 2027-07-22). Keep the team ID out of committed project files
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
hosted relay at https://relay.example.com (my-vm, email via Resend); real Claude called
`battery_status` and `laptop_status` through the connector, and got the immediate offline answer
after the app was quit.

## Next steps

Finishing the first version:
1. **Phone check (Toni):** ask Claude on the phone for the battery (US1).
2. **Measure Claude's tool-call time limit (Claude):** a temporary slow test tool on a test
   account, to confirm our 60 s cap sits below Claude's (T073).
3. **Public, signed releases (Toni, then Claude):** Apple Developer ID, the update signing key,
   and a public repository; then `macos/scripts/release.sh` publishes notarized builds with
   automatic updates (T082, T083).
4. **Before others use the hosted relay (Toni decides):** terms of service, privacy policy, and
   abuse handling; then lift the sign-up limit (`ALLOWED_EMAILS`).
5. **Later:** listing in Anthropic's connectors directory (one-click connect, no review screen).

Then the capabilities, one spec each, in this order (CLAUDE.md, step 6): each starts with
research and an interview of Toni, and stops for Toni's review before tasks or code.
6. Files (spec 002).
7. Notes and iMessage.
8. Shell.
9. Browser and computer control.

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
