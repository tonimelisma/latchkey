# 0009. Power and thermal monitoring

- Status: accepted
- Date: 2026-10-19
- Alias: plan 001 D8 (`specs/001-core/plan.md`, "D8. Power and thermal monitoring")

## Context and problem

Decision D8 of spec 001's plan (Core: connect Claude to the Mac); requirements in
[requirements/core.md](../requirements/core.md). Requirement IDs it cites: FR-032, FR-033, FR-034, FR-036.
The design it belongs to: [design/core.md](../design/core.md).

## Decision

Serves FR-032, FR-033, FR-034, FR-036, FR-063.
- Battery and power source: `IOPSCopyPowerSourcesInfo` and change notifications.
- Thermal: `ProcessInfo.thermalState` and `thermalStateDidChangeNotification`. Serious or critical
  turns keep-awake off.
- Low Power Mode is reported in state but does not by itself turn keep-awake off.
- Turning keep-awake off is reported at once in a `state` message (`keep_awake:
  off_low_battery` or `off_too_hot`); the Mac may stay awake and reachable for a while (lid open,
  in use). When macOS announces sleep (`NSWorkspace.willSleepNotification`), the app sends
  `goodbye` with reason `low_battery` or `too_hot` if keep-awake was off for that reason, else
  `system_sleep`, so the relay can answer "went to sleep for low battery at 14%". Power-off
  (`willPowerOffNotification`) sends `system_shutdown`; quitting sends `user_quit`.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/KeepAwakePolicyTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
