# 0018. Unsettled states, and the installer's checks of the running app

- Status: accepted
- Date: 2026-10-27
- Alias: plan 001 D17 (`specs/001-core/plan.md`, "D17. Unsettled states, and the installer's checks of the running app")

## Context and problem

Decision D17 of spec 001's plan (Core: connect Claude to the Mac); requirements in
[requirements/core.md](../requirements/core.md). Requirement IDs it cites: FR-621, FR-622, FR-620.
The design it belongs to: [design/core.md](../design/core.md).

## Decision

Serves FR-621, FR-622. Each setup step is a `SetupStep` (done, missing, unknown);
`SetupDecision` counts only `missing`. Location's state comes from `LocationFixer`'s
`locationManagerDidChangeAuthorization` (kept in `LocationFixer.known`), never from a fresh
manager, so it is `unknown` until Core Location's first callback. At start a paired Mac polls
every 250 ms, up to 5 s, until no step is unknown, then logs "Setup is finished" or "Opening
setup: missing …" (`permissions` category). `install.sh` then reads the app's own lines (FR-620):
the last keep-awake line must show the state the app wanted (waiting up to 90 s for launchd's
restart of the helper and the app's retries), the helper's start line must name the version
just installed while keep-awake is wanted, and the window count from the window server
(scripts/count-windows.swift) must be 0 unless the app logged why setup opened. The decisions
are functions in `install-lib.sh`, tested in `scripts/tests/install_checks_test.sh`. Options
considered: a fixed delay before deciding (rejected: a guess about timing), a UI test of the
real app (rejected: needs a second Mac or account for first-run states; the installer check
covers the installed Mac every time).

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/DiagnosticsTests.swift`
- `macos/Tests/PermissionLossTests.swift`
- `macos/Tests/SetupDecisionTests.swift`
- `scripts/tests/install_checks_test.sh`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
