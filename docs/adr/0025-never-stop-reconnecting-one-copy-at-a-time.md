# 0025. Never stop reconnecting; one copy at a time (FR-206, FR-207)

- Status: accepted
- Date: 2026-10-31
- Alias: plan 001 D24 (`specs/001-core/plan.md`, "D24. Never stop reconnecting; one copy at a time (FR-206, FR-207)")

## Context and problem

Decision D24 of spec 001's plan (Core: connect Claude to the Mac); requirements in
[requirements/core.md](../requirements/core.md). Requirement IDs it cites: FR-206, FR-207, FR-204.
The design it belongs to: [design/core.md](../design/core.md).

## Decision


- `ReconnectPolicy`: 4003 retries after 30 s, showing "Replaced by another connection"; 4001
  (refused sign-in) and 4004 (version) retry every 5 minutes, showing what the relay said, as a
  suspension already did (FR-204); only 4002 stops, since the key is gone. Options for 4003 were
  (a) 30 s, chosen: with one copy per Mac the other connection is gone or about to be; (b) the
  usual 1–30 s backoff, which would fight a second copy every few seconds; (c) never, the old
  behavior, which left the Mac offline.
- `RelayConnection` keeps the socket being opened apart from the welcomed one; state, tools,
  goodbye, and audit requests go only to the welcomed one, so the relay never sees them before
  the hello.
- `SingleCopy`: at launch, other running apps with this bundle identifier. None: start at once
  (so a link the app was opened with finds it started). Some: wait up to 10 s for them to quit,
  then quit with `exit(0)` without any quit steps (those would turn off keep-awake for the copy
  that stays). Options were (a) this, chosen; (b) a lock file, which outlives a crash; (c)
  letting the relay decide, which is what failed.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/ReconnectPolicyTests.swift`
- `macos/Tests/SingleCopyTests.swift`
- `relay/internal/hub/suspend_test.go`
- `relay/internal/server/guard_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
