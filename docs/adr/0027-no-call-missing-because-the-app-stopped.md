# 0027. No call missing because the app stopped (FR-666 to FR-668)

- Status: accepted
- Date: 2026-11-03
- Alias: plan 001 D27 (`specs/001-core/plan.md`, "D27. No call missing because the app stopped (FR-666 to FR-668)")

## Context and problem

Decision D27 of spec 001's plan (Core: connect Claude to the Mac); requirements in
[requirements/core.md](../requirements/core.md). Requirement IDs it cites: FR-666, FR-668, FR-667.
The design it belongs to: [design/core.md](../design/core.md).

## Decision


Options and the choice: research.md "Calls cut off by the app stopping".
- Marks (FR-667): before a call runs, `AppModel.handle` gives `CallsInFlight`
  (App/RunningCalls.swift) a `CallMark` (call id, start, tool, arguments, device, Claude app),
  kept in memory and written as one file per call in `Running calls` in the app's data folder,
  AES-GCM sealed with the activity log's key and bound to the call id. The file goes once the
  call's entry is written (or couldn't be). No log, no marks. Uninstall removes the folder with
  the rest of the data folder.
- Quit (FR-666): `applicationShouldTerminate` records `quitLine` ("Quitting with 1 call running;
  it is recorded as cut off by the quit"); `shutdown()`, after the goodbye to the relay (nothing
  can be answered after it), records every call still running as cut off, in one save, and a
  call that ends later isn't recorded again (`end` says so). The quit's 6-second deadline is
  unchanged.
- Start (FR-667): before connecting, marks left over are recorded as ended by the app stopping,
  except ids the log already has (`ActivityReader.logged`); a mark that can't be opened is
  removed and counted in an `activity` event.
- The comparison (FR-668): when calls are missing on the Mac, the app reads only the events in
  each one's window (`AuditComparison.quitWindow`: its start to the relay's end, 5 s either side)
  for an app event saying exactly "Quitting" (`ActivityReader.oldQuits`; every app before FR-666
  wrote that text at its quit, this one never does), and compares again: a missing call with
  outcome `error` or `timeout` and such a quit in its window goes to `cutOffByOldQuit`, named in
  the event ("1 call not on the Mac because Latchkey quit during it, before it recorded such
  calls: call_… (tool, time)") but not missing, so the installer's check passes. The relay's
  audit already shows how such a call ended: `error` with a duration up to the moment the Mac's
  connection closed (`hub.ErrDisconnected`).
- Relay: no change. The Mac's own quit event and the relay's end time are enough; marking the
  relay's audit row "the Mac disconnected" would change only rows from now on, which FR-666 and
  FR-667 already keep out of the gap.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/CutOffCallsTests.swift`
- `macos/Tests/UpdateGateTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
