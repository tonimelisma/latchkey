# 0174. Fast layer gates, on fake clocks (FR-1601, FR-1602)

- Status: accepted
- Date: 2026-11-25
- Alias: plan 016 D1 (`specs/016-test-strategy/plan.md`, "D1. Fast layer gates, on fake clocks (FR-1601, FR-1602)")

## Context and problem

Decision D1 of spec 016's plan (Test strategy and two ways to work); requirements in
[requirements/test-strategy.md](../requirements/test-strategy.md). Requirement IDs it cites: FR-1601, FR-1602.
The design it belongs to: [design/test-strategy.md](../design/test-strategy.md).

## Decision


- Swift: the deadline code takes an injected clock (Swift's `Clock` protocol: `ContinuousClock`
  in the app, a test clock that tests advance by hand). Every test in
  `macos/scripts/timing-suites.txt` and `quiet-suites.txt` moves to it; what still needs real
  time (a WebKit page's own events) asserts on order and outcome, never on a duration. The lists
  `timing-suites.txt` and `quiet-suites.txt` go once empty.
- Go: deadline tests use `testing/synctest` (Go 1.25+, the module is on 1.27) instead of
  sleeps.
- `ci.yml`'s Mac jobs: `continue-on-error` comes off the test steps once main is green three runs in
  a row; then the four test jobs become required checks in the ruleset `main` (a repository
  setting only the maintainer can change: one click in GitHub's settings, named exactly for him).
- Options weighed: (a) longer limits on CI only (hides real regressions, still flaky); (b)
  quarantine the ~30 (leaves deadlines untested); (c) fake clocks (deterministic, fast). Chose (c).

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/CodeFinderTests.swift`
- `macos/Tests/DeadlineTests.swift`
- `macos/Tests/ManualClock.swift`
- `relay/internal/account/account_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
