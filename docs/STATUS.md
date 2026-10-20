# Status

Last updated: 2026-10-20

Xcode signing ready (2026-10-20): Toni's Xcode account has a valid "Apple Development" certificate
(team ID `TEAMID1234`, expires 2027-07-22). Keep the team ID out of committed project files
(open source); put it in a gitignored `macos/Local.xcconfig` as `DEVELOPMENT_TEAM`.

## Current phase

Spec 001 (core) is written and reviewed. No code yet.

## Next steps

1. Write `specs/001-core/tasks.md` from `plan.md` and the contracts.
2. Milestone **M0**: keep-awake spike on Toni's Mac. A minimal Swift app plus an `SMAppService`
   helper that keeps the Mac awake with the lid closed on battery, through charger plug and
   unplug. Everything else depends on this working.
3. M1 relay hub and agent protocol with a Go test agent.

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

## Waiting on Toni

- Apple Developer ID (Toni is getting one). Until then, build with Apple Development signing.
