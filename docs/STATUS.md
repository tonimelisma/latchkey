# Status

Last updated: 2026-10-20 (tasks.md written)

Xcode signing ready (2026-10-20): Toni's Xcode account has a valid "Apple Development" certificate
(team ID `TEAMID1234`, expires 2027-07-22). Keep the team ID out of committed project files
(open source); put it in a gitignored `macos/Local.xcconfig` as `DEVELOPMENT_TEAM`.

## Current phase

Relay done through M2: hub, MCP surface (both protocol versions), OAuth (DCR, CIMD, PKCE, refresh
rotation), passkeys, email links, recovery, account page, pairing. Verified by unit and contract
tests, a headless-Chrome end-to-end test, and real Claude Code (`make claude-check`, passed
2026-10-20). Working through the rest of the plan in one go (Toni, 2026-10-20).

Note: the OAuth server code was written before its contract tests (Constitution VII asks for the
tests first). The tests were then written against the contract, run, and two expectations fixed.

Mac app (M3) built and tested: 32 Swift tests including a real Secure Enclave key and the shared
fixtures, and `make mac-check` running the real connection code against a relay. The helper and
lid-closed keep-awake run only after Toni approves the helper once in System Settings.

## Next steps

1. M4 and M5: everything not blocked on Toni; list the blocked steps at the end.

## Milestones (from `specs/001-core/plan.md`)

| # | Milestone | State |
|---|---|---|
| M1 | Relay hub + agent protocol, Go test agent | Done |
| M2 | OAuth, passkeys, pairing (relay side) | Done |
| M3 | Mac app: pairs, connects, keeps awake, answers `battery_status` | Done, except the helper approval step (Toni) |
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
