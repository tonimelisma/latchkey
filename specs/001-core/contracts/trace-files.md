# Trace files (Toni, 2026-11-15)

The full trace of everything Claude did through Latchkey, kept on every machine and on the relay
in files of one day each, so evals can be run over everything that happened anywhere. Requirements:
spec 001 FR-680 to FR-689, spec 010 FR-1057 to FR-1059. Choices and their alternatives:
`research.md` "Trace files".

## Rules on every side

- **One day, one file (or pair of files).** Named by the day in UTC, `YYYY-MM-DD`. An entry is
  filed under the UTC day of its `at` (for a call: when it began), whenever it is written.
- **Only ever appended to.** Nothing renames, rewrites, truncates, compacts, or deletes a trace
  file, and no upgrade or migration of any version touches one. The only removals: uninstalling
  (Mac, Linux server), and Delete account on the relay, which removes that account's folder.
  There is no age limit.
- **Versioned lines.** Every stored line is a JSON object whose `"v"` is its format version. A
  later format adds a new `v` for new lines; lines already written stay as written, and every
  reader keeps reading every version written before it. A line of a version the reader doesn't
  know, or one that doesn't parse (a write cut short by a crash or a full disk), is skipped and
  counted, never a reason to stop reading or to change the file.
- **Written to disk before it counts.** A writer appends the whole line and synchronizes the file
  (`fsync`) before it treats the entry as recorded.
- **Folders 0700, files 0600** on the relay and Linux. On the Mac the folder is in the Owner's
  Application Support, like the rest of the app's data.

## Mac: `~/Library/Application Support/Latchkey/activity/`

Two files a day; the small one holds each entry's fields in the clear (what the comparison with
the relay and the tamper check read), the large one the encrypted content (results with
screenshots reach several MB; Toni's log on 2026-11-15: 22,487 entries, 190 MB, the largest 3.9 MB).

- `YYYY-MM-DD.entries`: JSON Lines, one line per entry, version 1:

  | Field | Meaning |
  |---|---|
  | `v` | `1` |
  | `seq` | the entry's number in the tamper chain (FR-612); `0` for an entry from before the check |
  | `id` | the entry's UUID |
  | `at` | the entry's time: the bit pattern of its `timeIntervalSinceReferenceDate` (a Double) as 16 hex digits, so the chain's checksum over the exact time still holds |
  | `time` | the same time as ISO 8601 UTC with milliseconds; for people reading the file, never used by the app |
  | `kind` | `action` or `event` (FR-633) |
  | `call_id` | the relay's call id (FR-632), or `""` |
  | `device` | the pairing the call came through, or `""` |
  | `key` | which log key sealed it (16 hex digits, `-` for a key already gone, FR-203) |
  | `mac` | the chain's checksum, base64, or `""` |
  | `off`, `len` | where the sealed content is in the day's `.content` file (bytes) |

- `YYYY-MM-DD.content`: the sealed content of each entry, back to back with nothing between:
  AES-256-GCM combined form (12-byte nonce, ciphertext, 16-byte tag) over the entry's JSON (tool,
  arguments, result, isError, durationMS, client, inSystemLog, id, at), with the entry's `seq`
  and `id` as authenticated data when `seq` > 0 (unchanged from the database, FR-026a, FR-612).
- Writing: the content first, then the entries line; then both files are synchronized. Content
  with no entries line pointing at it (a crash between the two) is never read.
- The tamper chain (FR-612) and the Keychain record of the newest entry (FR-613) work exactly as
  before; the chain runs on across the days by `seq`.
- From the database: the first start of the version with daily files copies every row of
  `activity.store` into the files byte for byte (the sealed content, `seq`, `mac`, `key`
  unchanged, so the chain still checks), in a folder `activity.copying/`. Only when every row is
  written and read back (count, and the newest `seq`) is the folder renamed to `activity/`. A
  start that finds `activity/` never copies again; one that finds only `activity.copying/` (an
  interrupted copy) deletes that folder and copies again. `activity.store` and its side files are
  left on disk, untouched, for good; no version opens it for writing again.

## Linux server: `<data folder>/activity/`

- `YYYY-MM-DD.jsonl`: plain JSON Lines, readable only by the Owner's account, version 1:

  | Field | Meaning |
  |---|---|
  | `v` | `1` |
  | `at` | RFC 3339 UTC with milliseconds |
  | `kind` | `call` or `event` |
  | `call_id`, `tool`, `client` | as before |
  | `arguments` | the call's arguments exactly as they came (JSON), in full |
  | `result` | the content Claude was sent, the MCP content array as JSON (text, images, everything), in full |
  | `is_error`, `duration_ms` | as before |
  | `text`, `category`, `public` | an event's words, kind, and the words Claude may see (FR-1053) |

- The single file of earlier versions, `<data folder>/activity.jsonl` (arguments cut to 4,000
  characters, results to 2,000), is left as it is and still read: it is version 0 (lines with no
  `v`). Nothing writes to it any more.

## Relay: `<DATA_DIR>/traces/<account id>/`

- `YYYY-MM-DD.trace`: JSON Lines, version 1: `{"v":1,"sealed":"<base64>"}`. `sealed` is AES-256-GCM
  (12-byte nonce, ciphertext, 16-byte tag) under a key derived from the relay's key file
  (`KEY_FILE`, the one that seals its stored keys): HKDF-SHA256, info `latchkey relay traces v1`.
  The authenticated data is `<account id>/<day>`, so a line can't be moved to another account or
  day. Inside is one export line (below) with `source` `relay` and without `account` (the export
  adds the account's address at the time of export).
- What is traced: every tool call the relay answers for the account, the relay's own `machines`
  tool included, and calls answered without reaching a machine (offline, refused): the arguments
  exactly as Claude sent them (`machine` included), the full result exactly as Claude got it (the
  status line included, images included), outcome, duration, call id, the Claude app, and the
  machine. And the relay's events for the account (FR-631) as `kind` `event`.
- Low disk: while the file system that holds `traces/` has less than 2 GiB free, the relay writes
  no trace lines (everything else carries on) and records the event `traces_paused` once;
  when 2 GiB or more is free again it records `traces_resumed` and writes again. It never deletes
  a trace to make room (Toni, 2026-11-15: "a few screenshots might delete days of traces").
- Delete account (by the account or the operator) removes the account's folder.

## The export line (the same from every side)

One JSON object per line, UTF-8, oldest first. Every side's export writes this, so traces from
the Mac, the Linux servers, and the relay can be put together and joined by `call_id` (the
relay's line and the machine's line of one call carry the same id).

| Field | Meaning |
|---|---|
| `v` | `1` |
| `source` | `mac`, `linux`, or `relay` |
| `machine` | the machine's name (the relay: the machine the call went to, `null` when it reached none) |
| `time` | ISO 8601 with its UTC offset and milliseconds (when the call began) |
| `kind` | `action` (a tool call) or `event` |
| `tool` | the tool's name; for an event its category or kind |
| `arguments` | the arguments as JSON, or a string when they aren't JSON; `""` for an event |
| `result` | the MCP content array as JSON, or a string when it isn't JSON; for an event its text |
| `isError` | `true` when the call failed |
| `durationMS` | the call's duration in milliseconds; `0` for an event |
| `call_id` | the relay's call id, or `null` |
| `client` | the Claude app's name, or `null` |
| `outcome` | relay only: `ok`, `error`, `timeout`, or `offline` |
| `account` | relay only: the account's email address at the time of export |

The Mac's export has had `time` to `client` since 2026-10-27 (FR-615); `v`, `source`, and
`machine` come first now.

Where each export is:

- Mac: Activity window, Export… (FR-615), what the window's search and filters select.
- Linux: `latchkey activity export [--from YYYY-MM-DD] [--to YYYY-MM-DD]` to standard output;
  both days included, in UTC; version 0 lines included.
- Relay, operator: `relay trace export <email> [--from YYYY-MM-DD] [--to YYYY-MM-DD]` to
  standard output (inside the container: `docker exec latchkey-relay /relay trace export …`).
- Relay, the account: "Download full activity" on the account page, `GET /account/trace`, the
  signed-in account's whole trace as `latchkey-trace-<day>.jsonl`.
