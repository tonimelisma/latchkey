# 0012. Audit log and local trace

- Status: accepted
- Date: 2026-10-19
- Alias: plan 001 D11 (`specs/001-core/plan.md`, "D11. Audit log and local trace")

## Context and problem

Decision D11 of spec 001's plan (Core: connect Claude to the Mac); requirements in
[requirements/core.md](../requirements/core.md). Requirement IDs it cites: FR-022, FR-023, FR-024, FR-026, FR-026a, FR-610, FR-615, FR-022a, FR-611, FR-203, FR-077, FR-612, FR-616, FR-613, FR-614, FR-201, FR-202.
The design it belongs to: [design/core.md](../design/core.md).

## Decision

Serves FR-022, FR-023, FR-024, FR-026, FR-026a, FR-610 to FR-615, Constitution VI.
- Relay: one row per tool call, metadata only (no arguments, no results), with its call id; kept
  until the account is deleted, nothing deleted by age (D18; until 2026-10-27, a daily purge after
  30 days).
  "Surface" (FR-022) is the MCP `clientInfo.name` from the session's `initialize`, when sent,
  without control or formatting characters and cut to 64 characters (FR-022a).
- Mac app: full trace (arguments, results, errors, timings) in a local SQLite file in the app's
  Application Support folder (SwiftData, `activity.store`), shown in a log window from the menu bar. Never sent to the relay.
  Kept until uninstall: nothing is deleted by age (FR-026, decided 2026-10-26; the 90-day purge
  of earlier versions is gone). The window's footnote gives the store's size on disk, SQLite's
  side files included (FR-610). Disconnect, revocation, and pairing again touch only the
  pairing's Keychain items (`pairing`, `device-key`, `pairing-migrated`), never the log, its
  key, or its record (FR-611).
- Each entry is stored as its time (for sorting and the date filter) plus one AES-256-GCM sealed box (CryptoKit)
  holding tool, arguments, result, outcome, and duration (FR-026a). The key is 256 random bits,
  made on first use and kept as a generic password in the login Keychain (this Mac only,
  readable after first unlock); its access list trusts only the app that created it, so another
  program asking for it makes macOS ask the Owner. Entries are decrypted only to show them; one
  whose key is gone is left out of the menu and the window's table, and the window says how many
  such entries there are (FR-203; counted by a query on the entry's key ID, without decrypting). The plaintext log of earlier versions (`trace.store`) is
  encrypted into the new file once at start, then its files are deleted. Uninstall (FR-077)
  deletes the key too. Tests use an in-memory key, never the Keychain.
- Tamper check (FR-612, research.md "Tamper-evident activity log"): each entry recorded from this change on
  has a number `seq` (1, 2, … across keys), a key ID (8 bytes HKDF-derived from the log key, as
  hex), and `mac` = HMAC-SHA256, under a second HKDF-derived key, over the previous entry's mac
  (32 zero bytes for the first), seq, the entry's ID, its stored time, and the key ID. Its sealed
  box binds seq and ID as authenticated data, so content can't be swapped between rows. The
  check walks the entries under the current key in seq order, reading only the clear fields,
  and lists each entry whose mac doesn't follow (resyncing on its stored mac, so later breaks
  are found too); a sealed box under the current key that no longer opens counts as changed.
  The window runs it off the main thread each time it opens (FR-616). Entries from before (seq 0) are
  shown with "Before check". The upgrade is SwiftData's in-place migration (the new fields have
  defaults), then one pass that gives every old entry the ID of the key that opens it (or "-")
  in a single save; a failed save changes nothing and is retried at the next start.
- Newest-entry record (FR-613): Keychain item `activity-log-latest` (57 bytes: version, key ID,
  seq, mac), added when there is none and then replaced with `SecItemUpdate` (no moment without
  it) after each save, never before. At start: no record → fine, or "missing" when checked
  entries exist (said in one line; the next entry adds one); a record that can't be read or isn't
  understood → left alone and not written for the launch, one line said, no alarm; a record of
  another key → replaced as entries come. The chain continues from the newer of the record and
  the log, so an end cut off stays visible as a break at the next entry. The check warns
  "newer entries are missing" when the record's entry is gone with nothing after it, naming the
  newest entry still there; the wording also allows for a power cut losing the last write.
- Browsing (FR-614): pages of 200, newest first, continued from the last shown entry (time, seq)
  with a time-range query the `(at, seq)` index serves; the date filter is part of that query.
  Text and tool are matched after decrypting, in batches of 1,000, on every core, on a
  `ModelContext` of its own off the main thread; nothing searchable is stored in the clear.
  Export… (FR-615) writes the same query oldest first, a page at a time, as JSON Lines to the
  file chosen in `NSSavePanel`. Timings for 100,000 entries are in research.md.
- Opening the window (FR-616, 2026-10-29): the window's reads go through `ActivityLoading`, which
  runs each on a detached task (the first page at user-initiated priority, the tamper check at
  utility) and hands back small rows; the window shows "Checking the activity log for changes…"
  and an empty Check column until the check returns. Queries that walk the chain ask by `seq`
  alone, so SQLite reads them in order from the `seq` index, and skip other keys' rows in
  Swift: the check's batches of 5,000, the count of entries from before the check, and, at
  start, the newest entry under the current key (64 rows at a time, newest first). Asking for
  "key ID = this key and seq > n" made SQLite use the key-ID index and sort every entry of the
  key for each batch (seen with `EXPLAIN QUERY PLAN` on a generated store: `USE TEMP B-TREE FOR
  ORDER BY`). The menu's newest entries are read off the main thread after every call, newest
  load wins, without counting unreadable entries (`countUnreadable: false`). Measured
  2026-10-29 on 100,000 entries of about 1 KB: open 0.003 s (was 0.06 s and growing), first page
  0.013 s, menu 0.003 s, check 0.73 s at 20,000 and 4.0 s at 100,000 (linear; mostly SwiftData
  reading each row's clear fields), main-thread record and menu read during the check at most
  0.009 s. `ActivityLogScaleTests` fails when any of these grows with the log;
  `ActivityWindowLoadingTests` fails when the window's reads run on the main thread.
- The Keychain look (`Keychain.lookup`) answers one of three things: no item (only when the
  search itself says "not found"), the item's data, or "there is an item that can't be read"
  (every other failure: a Keychain error, more than one match, no data). A new log key is made
  only on "no item", and saved with a write that refuses to replace; on "can't be read", or a key
  that isn't 32 bytes, the log is unavailable for the launch (`ActivityLog.unavailable` with the
  sentence shown in the Activity window; the menu says "Activity Log Unavailable"), the reason is
  logged at error level, and nothing is written (FR-201). The pairing record is read with the
  same look; no code path at start writes or deletes it, and the start line in the log says
  "pairing record present but unreadable" instead of "missing pairing record" (FR-202).

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/ActivityLogKeyTests.swift`
- `macos/Tests/ActivityLogScaleTests.swift`
- `macos/Tests/ActivityLogTests.swift`
- `macos/Tests/ActivityWindowLoadingTests.swift`
- `macos/Tests/AuditTrailTests.swift`
- `macos/Tests/InstallationTests.swift`
- `macos/Tests/KeychainTests.swift`
- `macos/Tests/TraceFilesTests.swift`
- `macos/Tests/TraceTests.swift`
- `relay/internal/mcpserver/mcpserver_test.go`
- `relay/internal/server/events_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
