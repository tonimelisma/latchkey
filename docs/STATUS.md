# Status

Last updated: 2026-10-22 (spec 002 increment 2)

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
Phone check done. Claude's tool time limit is documented (240 s), so no measurement is needed.

1. **Spec 002, Notes and Messages** (approved; branch `002-notes-messages`; `tasks.md`).
   Increment 1 done (app 0.2.0, relay deployed): state line in every Mac answer, status tools
   removed, Off / Read only / Read & write levels, activity in the menu, busy dot, notifications,
   Full Disk Access setup step. Increment 2 done (app 0.3.0): Claude can search, list folders, read notes (with
   checklists), and view note images. Increment 3 done (app 0.4.0): create, append, replace, edit
   a passage, delete (to Recently Deleted), all through Notes with AppleScript; notes with
   checklists, images, or tables are refused with the reason; setup asks for permission to
   control Notes. Checked against a test database and a stand-in for Notes, not yet against
   Toni's real Notes (needs 0.4.0 installed with Full Disk Access and Notes control allowed).
   Increment 4 done (app 0.5.0): Claude can list conversations, read them, search all history by
   words, person, and time, and view images, with names from Contacts and other people's words
   marked as not instructions; setup asks for Contacts. Checked against a test database (a
   200,000-message search takes 0.2 s), not yet against Toni's real messages.
   Increment 5 done (app 0.6.0): Claude can send messages with text and files to a person, number,
   address, group, or conversation, with confirmation from Messages; setup asks for permission to
   control Messages. Checked against a test database and a stand-in for Messages.
   Next: Toni installs 0.6.0 and finishes setup (one sitting, see "Waiting on Toni"), then Claude
   runs the live checks through the connector (tasks T141).
3. Then Files, Shell, Browser and computer control, one spec each.

## Waiting on Toni

1. Install `macos/build/Latchkey-0.6.0.dmg` (drag to Applications, replace the old copy) and open it.
2. In the setup window: turn on Latchkey under Full Disk Access, then click Continue on the Notes,
   Messages, and Contacts steps and choose Allow each time macOS asks.

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
