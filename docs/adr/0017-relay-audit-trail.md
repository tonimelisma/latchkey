# 0017. Relay audit trail

- Status: accepted
- Date: 2026-10-27
- Alias: plan 001 D18 (`specs/001-core/plan.md`, "D18. Relay audit trail")

## Context and problem

Decision D18 of spec 001's plan (Core: connect Claude to the Mac); requirements in
[requirements/core.md](../requirements/core.md). Requirement IDs it cites: FR-022, FR-024, FR-630, FR-637, FR-632, FR-022a, FR-634, FR-091, FR-631, FR-635, FR-195.
The design it belongs to: [design/core.md](../design/core.md).

## Decision

Serves FR-022, FR-024, FR-630 to FR-637; Constitution II (the comparison never waits on the
Mac: the relay answers from its own database) and VI (metadata only, fixed words, no
addresses, bounded for strangers).
- Nothing is deleted by age: the 30-day purge of `audit_log` is gone, and the daily
  housekeeping (`Relay.Daily`) touches neither the audit nor `events`. Deleting the account
  deletes both (foreign keys with cascade). A test runs the housekeeping 1, 5, and 30 years
  ahead and finds every row.
- Call ids (FR-632): `agentproto.NewCallID`, `call_` and 16 bytes from `crypto/rand` in
  Crockford base32 (26 characters, upper case). The MCP layer makes the id before it looks at
  the Mac, so a call answered "offline" or "never paired" has one too, sends it in `call`, and
  stores it in `audit_log.call_id` (migration 12; old rows `''`). The audit write no longer
  shares the request's cancellation, so a call whose client went away is audited as well.
- The Claude app's name in each call (FR-637): the surface the audit stores (the session's
  `clientInfo.name`, cleaned as FR-022a says) is computed once per call and sent as `call.client`,
  left out when unknown, so the Mac's log and the relay's audit name the app the same way.
- Audit comparison (FR-634, contract "Audit comparison"): a connection whose hello listed
  `audit` may send `audit_request`; the relay answers from `AuditForDevice` (this Mac's rows,
  `at >= since`, oldest first, at most the limit cut to 1000) with `next_since`. A page never
  ends inside a millisecond whose rows go on: those rows start the next page. An invalid
  `since` or `limit` gets an empty page and `null`. `audit_request` from a connection without
  the feature closes it with 4005, and `audit` is never sent unasked, so apps before the
  feature never see the message. The request counts against the frame allowance (FR-091).
- Event record (FR-631): table `events` (migration 12, data-model.md) written through
  `internal/events.Recorder`, which stores each event and logs one `slog` line with the event's
  kind, account, Mac, and detail. Recorded by the hub (connected with versions, keep-awake, and
  features; disconnected with close code, reason, and goodbye reason; keep-awake changes from
  hello, `state`, and `goodbye`, only on change; refused handshakes; Disconnect in the app),
  the account pages (each sign-in step and outcome by passkey, emailed code, and recovery;
  pairing; unpairing on the account page, by a new pairing, and with the account), and the
  OAuth server (approved, refused on the consent page, removed on the account page, from the
  Mac app, by a recovery, by the client's own revocation or token reuse, and by expiry in the
  daily purge, which now returns the approvals it ended). Every refused or failed HTTP request
  (status 400 and up) is recorded by the outermost handler with its route pattern (never the
  path the client sent), status, and a reason the handler noted (`events.Note`: "no token",
  "token rejected: …", "rate limit per address", "request too large", …) or the status's
  meaning.
- Strangers can't grow the record (research.md "The relay's event record"): refusals, refused
  handshakes, and sign-in steps anyone can cause are counted, one row per hour, kind, account,
  and detail, and only the first of each hour is logged. Details are fixed words, so the rows
  without an account grow by at most one per kind and reason an hour.
- Output (FR-635): the MCP SDK's server gets the relay's logger filtered to warnings and errors,
  so its "server connecting", "session connected", and "session disconnected" lines per request
  are gone and its warnings stay. The relay's output is the event lines, warnings, and errors.
- Not recorded as events: the operator's commands (they have `operator_log`, FR-195, and run in
  another process), and the account's deletion, which is only logged (its record goes with it).

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/AuditTrailTests.swift`
- `relay/agentproto/agentproto_test.go`
- `relay/agentproto/audit_test.go`
- `relay/cmd/relay/operator_test.go`
- `relay/internal/account/events_test.go`
- `relay/internal/account/legal_test.go`
- `relay/internal/hub/audit_test.go`
- `relay/internal/hub/clients_test.go`
- `relay/internal/hub/hub_test.go`
- `relay/internal/mcpserver/audit_test.go`
- `relay/internal/mcpserver/mcpserver_test.go`
- `relay/internal/server/events_test.go`
- `relay/internal/store/events_test.go`
- `scripts/tests/install_checks_test.sh`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
