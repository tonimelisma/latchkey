# 0028. Latchkey's log for Claude (FR-662 to FR-665)

- Status: accepted
- Date: 2026-11-03
- Alias: plan 001 D26 (`specs/001-core/plan.md`, "D26. Latchkey's log for Claude (FR-662 to FR-665)")

## Context and problem

Decision D26 of spec 001's plan (Core: connect Claude to the Mac); requirements in
[requirements/core.md](../requirements/core.md). Requirement IDs it cites: FR-662, FR-665, FR-663, FR-612.
The design it belongs to: [design/core.md](../design/core.md).

## Decision


- Tool `latchkey_log` (contracts/mcp-surface.md), `App/LatchkeyLog.swift`. It sits in
  `CapabilityRegistry.always`, offered whatever the levels; Pause refuses it like every call.
  Why not a capability with its own switch, and why not the activity log's other entries:
  research.md "Latchkey's log for Claude".
- Source: the activity log's events (D19), read with `ActivityQuery(kind: .event,
  inSystemLogOnly: true)`, so lines survive restarts and installs. `EventLog.record` now marks
  each event with `inSystemLog` (its `systemLog` argument), sealed with the content like
  `client`, so the mark is encrypted and old entries open as before; entries without the mark
  (recorded before 2026-11-03) are never returned (FR-663). `kind` is chained (FR-612), so an
  action can't pass as an event.
- Without the activity log (FR-665): `EventLog` keeps this launch's newest 1000 public lines in
  memory (`recentPublic`), filled whether or not the log is open.
- Size: the newest lines that fit in `ResultLimit.characters` with the header; one line is at
  most 2000 characters; line breaks in a text become spaces.
- Relay: none. It forwards the Mac's tool list generically (D2); the `machines` tool now lists
  `latchkey_log` among what a Mac offers, also with every capability off. Linux (spec 010): not
  offered; its program logs to the journal, a separate job.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/ActivityLogTests.swift`
- `macos/Tests/LatchkeyLogTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
