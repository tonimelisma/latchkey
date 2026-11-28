# 0029. Full traces in daily files (FR-680 to FR-689; spec 010 FR-1057 to FR-1059)

- Status: accepted
- Date: 2026-11-15
- Alias: plan 001 D28 (`specs/001-core/plan.md`, "D28. Full traces in daily files (FR-680 to FR-689; spec 010 FR-1057 to FR-1059)")

## Context and problem

Decision D28 of spec 001's plan (Core: connect Claude to the Mac); requirements in
[requirements/core.md](../requirements/core.md). Requirement IDs it cites: FR-680, FR-689, FR-1057, FR-1059, FR-686, FR-682, FR-612, FR-613, FR-683, FR-685, FR-687, FR-688.
The design it belongs to: [design/core.md](../design/core.md).

## Decision


decided 2026-11-15: full traces everywhere, for evals over everything that happened anywhere, kept
where no migration can wipe them. Formats: `docs/design/contracts/trace-files.md`; options weighed:
research.md "Trace files".

- One shape on every side: files named by the UTC day, only ever appended to, every line carrying
  its format version; a reader skips and counts what it can't read and never changes a file.
  Every side exports the same line (FR-686), and `call_id` joins a relay line to its machine line.
- Mac (FR-682): `TraceFiles` (App/Trace.swift) holds two files a day, `.entries` with each
  entry's fields in the clear (what the tamper check, the comparison with the relay, and paging
  read) and `.content` with the sealed content back to back. `ActivityReader` reads the files a
  day at a time, newest day first; sealing, the chain (FR-612), and the Keychain record (FR-613)
  are unchanged. The first start copies the database's rows byte for byte (read with SQLite from
  a copy of its files, never through SwiftData, which may change a store just by opening it) into
  `activity.copying/`, reads them back, and renames the folder; `activity.store` stays on disk as
  it was. The copy is recorded as an app event. SwiftData is no longer used by the app.
- Relay (FR-683 to FR-685, FR-687, FR-688): package `internal/trace`, written by `mcpserver`
  for every call (every outcome of `forward`, and the `machines` tool) and by
  `events.Recorder.TraceTo` for an account's events (counted events only as often as they are
  logged, so no one can grow a trace without limit); opened through `server.TraceOptions` by the
  server and the operator commands alike, so both use one key (`Store.DeriveKey`, HKDF over the
  key file's bytes, which never leave the store); removed in Delete account, the operator's
  `account delete`, and the daily purge of unfinished sign-ups; a folder is made only for an
  account that still exists, so a call ending after a deletion doesn't bring it back; each line sealed
  with AES-256-GCM under a key derived from the key file (HKDF, its own info string), bound to the
  account and day. Below 2 GiB free it writes nothing and records `traces_paused` and
  `traces_resumed`. Delete account removes the account's folder. `relay trace export` and
  `GET /account/trace` write the export line. No agent protocol change: the relay already sees
  every argument and result it forwards.
- Linux (FR-1057 to FR-1059): `activity/YYYY-MM-DD.jsonl`, plain, 0600, arguments and the whole
  content array in full; the old `activity.jsonl` read as version 0 and never written again;
  `latchkey activity export`.

## Confirmation

The tests that validate the requirements it cites:

- `linux/internal/activity/activity_test.go`
- `linux/internal/activity/export_test.go`
- `linux/internal/agent/log_test.go`
- `macos/Tests/ActivityLogTests.swift`
- `macos/Tests/KeychainTests.swift`
- `macos/Tests/TraceFilesTests.swift`
- `relay/cmd/relay/operator_test.go`
- `relay/internal/account/legal_test.go`
- `relay/internal/account/trace_test.go`
- `relay/internal/events/events_test.go`
- `relay/internal/mcpserver/trace_test.go`
- `relay/internal/operator/operator_test.go`
- `relay/internal/server/trace_test.go`
- `relay/internal/store/sealed_test.go`
- `relay/internal/store/signin_test.go`
- `relay/internal/trace/trace_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
