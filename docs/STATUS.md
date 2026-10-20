# Status

Last updated: 2026-10-20 (tasks.md written)

Xcode signing ready (2026-10-20): Toni's Xcode account has a valid "Apple Development" certificate
(team ID `TEAMID1234`, expires 2027-07-22). Keep the team ID out of committed project files
(open source); put it in a gitignored `macos/Local.xcconfig` as `DEVELOPMENT_TEAM`.

## Current phase

Spec 001 (core) is written and reviewed. `specs/001-core/tasks.md` is written (T001 to T085, by
milestone). No code yet.

## Next steps

1. M0, tasks T001 to T005: Mac project skeleton (XcodeGen), helper daemon with XPC and
   `pmset disablesleep`, and the spike app that registers it and re-applies on power changes.
2. M0, task T006: hardware run on Toni's Mac (lid closed on battery, charger cycles). Needs Toni at
   the Mac. **Gate:** if it fails, revisit plan D7 before M1.
3. M1 (T010 to T022): relay hub and agent protocol with a Go test agent.

## Milestones (from `specs/001-core/plan.md`)

| # | Milestone | State |
|---|---|---|
| M0 | Keep-awake spike on real hardware | Not started |
| M1 | Relay hub + agent protocol, Go test agent | Not started |
| M2 | Mac app connects, answers `battery_status` | Not started |
| M3 | OAuth, passkeys, pairing | Not started |
| M4 | End to end from Claude on phone, web, Desktop | Not started |
| M5 | Signing, notarization, Sparkle, Docker image | Not started |

## Risks

- **Highest: lid-closed keep-awake on Apple silicon.** `pmset disablesleep` is the only mechanism
  that prevents clamshell sleep, and reports conflict on whether it survives charger plug and
  unplug. M0 tests it first. If it fails, revisit plan decision D7 before building anything else.

## Open questions

| Question | Resolve by |
|---|---|
| Domain for the hosted relay | Toni, before M4 |
| Claude's hosted-client tool-call timeout (undocumented) | Measure in M4; keep our 60 s cap below it |
| Do `SMAppService` daemons run with free Personal Team signing? | Test in M0 |
| Terms, privacy policy, abuse handling for the hosted relay | Launch blocker, deferred |
| Agent protocol needs a relay → Mac notice message to announce account recovery in the app (T061) | Toni, before M3 |
| License: MIT or Apache-2.0 (T085) | Toni, before M5 |

## Waiting on Toni

- Apple Developer ID (Toni is getting one). Until then, build with Apple Development signing.
