# Status

Last updated: 2026-10-20 (tasks.md written)

Xcode signing ready (2026-10-20): Toni's Xcode account has a valid "Apple Development" certificate
(team ID `TEAMID1234`, expires 2027-07-22). Keep the team ID out of committed project files
(open source); put it in a gitignored `macos/Local.xcconfig` as `DEVELOPMENT_TEAM`.

## Current phase

Relay core (M1) done: the pretend Mac, the hub, offline messages, the MCP surface for both protocol
versions, and the audit log, all with tests. Working through the rest of the plan in one go
(Toni, 2026-10-20).

## Next steps

1. M2: OAuth, passkeys, email, pairing, account pages, browser sign-in test, Claude Code check.
2. M3: Mac app.
3. M4 and M5: everything not blocked on Toni; list the blocked steps at the end.

## Milestones (from `specs/001-core/plan.md`)

| # | Milestone | State |
|---|---|---|
| M1 | Relay hub + agent protocol, Go test agent | Done |
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
| Domain for the hosted relay, and where the public test relay runs | Toni, before M4 |
| Claude's hosted-client tool-call timeout (undocumented) | Measure in M4; keep our 60 s cap below it |
| Terms, privacy policy, abuse handling for the hosted relay | Launch blocker, deferred |

## Waiting on Toni

- Apple Developer ID (Toni is getting one). Until then, build with Apple Development signing.
