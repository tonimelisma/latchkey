# Status

Last updated: 2026-10-20 (tasks.md written)

Xcode signing ready (2026-10-20): Toni's Xcode account has a valid "Apple Development" certificate
(team ID `TEAMID1234`, expires 2027-07-22). Keep the team ID out of committed project files
(open source); put it in a gitignored `macos/Local.xcconfig` as `DEVELOPMENT_TEAM`.

## Current phase

Spec 001 (core) is written and reviewed. M1 started: relay module, protocol fixtures, `agentproto`,
and `store` are in, with tests and lint passing.

## Next steps

1. M1, tasks T015 to T017: Go test agent, agent protocol contract tests, hub. Ask Toni first:
   the relay's listen address and port settings for self-hosters (D10 lists no variable for it).
2. M1, tasks T018 to T022: offline messages, MCP surface, audit log.
3. M2: OAuth, passkeys, pairing on the relay.

## Milestones (from `specs/001-core/plan.md`)

| # | Milestone | State |
|---|---|---|
| M1 | Relay hub + agent protocol, Go test agent | In progress: T010 to T014 done |
| M2 | OAuth, passkeys, pairing (relay side) | Not started |
| M3 | Mac app: pairs, connects, keeps awake, answers `battery_status` | Not started |
| M4 | End to end from Claude on phone, web, Desktop | Not started |
| M5 | Signing, notarization, Sparkle, Docker image | Not started |

## Risks

- Lid-closed keep-awake relies on `pmset disablesleep`, which Apple does not document; reports
  conflict on Apple silicon charger changes. Mitigation: re-apply and read back on every power
  change and wake (plan D7). No spike or hardware test runs (Toni, 2026-10-20).

## Open questions

| Question | Resolve by |
|---|---|
| Domain for the hosted relay | Toni, before M4 |
| Claude's hosted-client tool-call timeout (undocumented) | Measure in M4; keep our 60 s cap below it |
| Terms, privacy policy, abuse handling for the hosted relay | Launch blocker, deferred |

## Waiting on Toni

- Apple Developer ID (Toni is getting one). Until then, build with Apple Development signing.
