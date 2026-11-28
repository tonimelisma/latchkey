# 0020. Mac audit trail

- Status: accepted
- Date: 2026-10-27
- Alias: plan 001 D19 (`specs/001-core/plan.md`, "D19. Mac audit trail")

## Context and problem

Decision D19 of spec 001's plan (Core: connect Claude to the Mac); requirements in
[requirements/core.md](../requirements/core.md). Requirement IDs it cites: FR-026, FR-610, FR-632, FR-634, FR-636, FR-637, FR-633, FR-620, FR-640, FR-643.
The design it belongs to: [design/core.md](../design/core.md).

## Decision

Serves FR-026, FR-610, FR-632 to FR-634, FR-636, FR-637; Constitution II, VI. Options and the
measurements are in research.md ("The Mac's audit trail").
- Stored shape: `SealedActivity` gains `kind` ("action" or "event"), `callID`, and `device` in
  the clear, with defaults, so SwiftData upgrades the maintainer's log in place (old rows read as actions
  without a call id). The chain's checksum covers the three whenever one isn't its default, so
  old checksums still hold and a changed kind or id breaks the chain. The Claude app's name
  (`client`, FR-637) is sealed with the content. `AuditTrailTests` upgrades a chained log in the
  0.8.15–0.8.23 schema and checks every entry, the chain, and the record.
- Events (FR-633): `EventLog` (App/EventLog.swift), callable from any thread, writes each event
  to macOS's log (FR-620, same categories, `audit` added) and into the activity log, waiting in
  memory until the log is open and keeping events after a failed save. The kinds are
  `EventCategory`: app (start, quit, uninstall, errors shown), connection (connects, closes with
  code and reason, retries, network changes), keep-awake decisions (only on change), the
  helper's failures as the app sees them (once until they go away), power (sleep, wake,
  shutdown), permissions (requests, answers, every change of the approvals line), setup
  decisions, pause, pairing (paired, links, Disconnect, revoked), activity-log problems that
  can be recorded, and audit results. The menu shows Claude's actions only; the Activity window
  has a Show filter (everything, Claude's actions, Latchkey events) and a Claude App column;
  Export adds `kind`, `call_id`, and `client`.
- Left Behind (FR-640 to FR-643): a further `EventCategory`, `leftovers`, recorded with
  `systemLog: false`. The Show filter gains Left Behind (events of that category). A tool result
  carries `made` (what it created, "the note “Plan”"), which the app records as "Claude made
  …" after the call. Shell's entries and the notification are spec 004 D10, D11.
- Calls (FR-632, FR-637): each action stores the `call`'s `id`, the pairing's device ID, and the
  `client` it named.
- Comparison (FR-634): after each `welcome` (the connection's `connected` hook, not awaited by
  it) and from Check Against Relay in the Activity window, the app asks for the relay's audit
  from the start, 1,000 rows a page, 15 s per page, and checks each page (no more than asked,
  nothing before `since`, `next_since` past the newest row, a million rows in all).
  `AuditComparison.compare` is a pure function; its result is one event naming every missing
  call ("Audit check: 412 calls match; missing on the Mac: call_… (tool, time); …" or "Audit
  check: all 412 calls match"), also in macOS's log under `audit`, and a warning in the Activity
  window while any is missing. A relay that doesn't answer in time gives "Audit check not
  possible: the relay didn't answer". Older relays aren't supported (decided 2026-10-27).
- Installer (FR-636): `install.sh` waits up to two minutes for the new app's "Audit check" line
  and fails (`audit_verdict` in install-lib.sh) on anything but "Audit check: all …", an
  unpaired Mac excepted.
- No age-based deletion anywhere on the Mac: `AuditTrailTests` keeps events 20 years old and
  checks that no app code deletes activity rows; uninstall removes the whole file.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/AuditTrailTests.swift`
- `macos/Tests/DiagnosticsTests.swift`
- `macos/Tests/TraceTests.swift`
- `relay/agentproto/audit_test.go`
- `relay/internal/account/events_test.go`
- `relay/internal/hub/audit_test.go`
- `relay/internal/mcpserver/audit_test.go`
- `relay/internal/server/events_test.go`
- `relay/internal/store/events_test.go`
- `scripts/tests/install_checks_test.sh`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
