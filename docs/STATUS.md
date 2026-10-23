# Status

Last updated: 2026-10-22 (specs 003–006 built)

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

Releases, terms and privacy, and the directory listing are much later (Toni, 2026-10-22).

1. **All capabilities are built** (app 0.7.0, 2026-10-22): Notes and Messages (spec 002), Files
   (003), Shell (004), Browser through Toni's Safari (005), Computer control (006). 152 Mac tests
   pass; Notes, Messages, Safari scripts compile against the real apps; Files and Shell are tested
   with real files and commands. Not yet checked on Toni's real data or with the real
   permissions (the installed app is 0.1.2, quit).
2. When Toni has installed 0.7.0 and finished setup (see "Waiting on Toni"), Claude runs the live
   checks through the connector: read a note, change a test note, read a conversation, send the
   one test message to owner@example.com, search and read a file, run `df -h`, open and read a
   page in Safari, take a screenshot (tasks 002 T141 and the same for 003–006).
3. Toni reviews specs 003–006 (built without review stops, at Toni's request).

## Waiting on Toni

1. Install `macos/build/Latchkey-0.7.4.dmg` (drag to Applications, replace the old copy) and open it.
2. In the setup window, top to bottom: Full Disk Access; Continue (then Allow) for Notes,
   Messages, Contacts, Safari, Screen Recording, and Accessibility; and in Safari's settings turn
   on "Show features for web developers" (Advanced) and "Allow JavaScript from Apple Events"
   (Developer), then click Check.

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
