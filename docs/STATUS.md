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

## Next steps (each needs Toni; everything around them is ready)

1. **Install the app:** open `macos/build/Latchkey-0.1.0.dmg`, drag Latchkey to Applications,
   open it, and follow the setup window (approve keep-awake in System Settings, connect).
2. **Hosted relay live at https://relay.example.com** (deployed 2026-10-20, Let's Encrypt
   certificate, 7 MB memory on my-vm). Sign-up emails wait on the Resend sending domain: Toni adds
   a full-access `RESEND_ADMIN_KEY` to `.env`, then Claude reruns `deploy/deploy-vps.sh`.
3. **Try it from your Claude account and devices** (T072 to T074): add the connector on claude.ai,
   ask from the phone and Desktop. Checklist: `specs/001-core/quickstart.md`. Claude measures the
   hosted tool-call timeout (T073) from the relay's logs during this.
4. **Developer ID, update key, public repository** for signed releases and updates (T082, T083):
   setup steps are at the top of `macos/scripts/release.sh`; then one command publishes.

## Milestones (from `specs/001-core/plan.md`)

| # | Milestone | State |
|---|---|---|
| M1 | Relay hub + agent protocol, Go test agent | Done |
| M2 | OAuth, passkeys, pairing (relay side) | Done |
| M3 | Mac app: pairs, connects, keeps awake, answers `battery_status` | Done; helper waits for approval |
| M4 | End to end from Claude on phone, web, Desktop | Ready; needs domain, host, Toni's devices |
| M5 | Signing, notarization, Sparkle, Docker image | Container done; release needs Developer ID |

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
