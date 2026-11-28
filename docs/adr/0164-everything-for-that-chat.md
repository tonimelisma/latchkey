# 0164. Everything for that chat (FR-1440 to FR-1456; 2026-11-25)

- Status: accepted
- Date: 2026-11-25
- Alias: plan 014 D7 (`specs/014-feedback-intake/plan.md`, "D7. Everything for that chat (FR-1440 to FR-1456; 2026-11-25)")

## Context and problem

Decision D7 of spec 014's plan (Problem reports to the developer); requirements in
[requirements/feedback-intake.md](../requirements/feedback-intake.md). Requirement IDs it cites: FR-1440, FR-1456, FR-1441, FR-1442, FR-1443, FR-1445, FR-1444, FR-1446, FR-1447, FR-1448, FR-1451, FR-1455, FR-1452.
The design it belongs to: [design/feedback-intake.md](../design/feedback-intake.md).

## Decision


- **The chat's calls** (FR-1440, FR-1441): the relay's trace line (contract trace-files.md) gains
  `session`, the connector session's id (`req.Session.ID()`; empty for stateless clients). At a
  report the relay reads the account's trace for today and yesterday (`trace.Store.Each`) and
  keeps the lines of the report's session, plus the lines of earlier sessions (24 h) whose
  arguments name a page (`page`) one of the report's session's lines named; without a session,
  the same client's lines of the last 2 hours. No trace store (tests, a relay without traces):
  no calls, said in the report.
- **The relay's log** (FR-1442): `internal/reportlog`, a `slog.Handler` that wraps the relay's
  handler and keeps, for each record carrying a `user` attribute, its time, level, message and
  attributes (without `user`) in a ring of 500 per account, in memory, forgotten after 24 hours.
- **A machine's part** (FR-1443 to FR-1445): the relay calls the machine through the existing
  `call`/`result` messages with the tool `latchkey_report_part` (agentproto.ReportPartTool),
  only to machines whose hello lists the feature `report_part`, all at once, each with a 10 s
  deadline. Arguments: `since`, `until` (ms), `call_ids`, `pages` (the page names the calls used),
  `max_bytes` (3.5 MB, under the 4 MB frame). The answer is one text content holding the part's
  JSON (contract feedback-intake.md). No new message type, so an old relay or app never sees one;
  `ValidateTools` refuses a machine tool of that name. The call isn't traced or audited as
  Claude's on any side; the machine records an event "sent its part of a problem report".
- **The Mac** (FR-1444, FR-1446, FR-1447): `App/ReportPart.swift` answers the call before the
  capability registry. Log: the activity log's public events in the span. Trace: the activity
  entries of the call ids. Pages: `OwnPages.describe(names)`. Each `LockedBrowser` gets a
  `PageRecord` (300 events, memory only) fed by its navigation delegate (method from the action,
  status from the response) and by a script in the content world `latchkey-record`
  (`WKUserScript`, document start, main frame), which posts PerformanceObserver resource entries,
  `error`, `securitypolicyviolation` and `visibilitychange` through a
  script message handler that exists only in that world. The snapshot runs in the same world:
  `outerHTML` of a clone whose `input`/`textarea`/`select` values and `value` attributes are
  blanked, visibility, focus, frames counted for 500 ms, sizes; cookie names from the page's
  store; a screenshot (`LockedBrowser.screenshot`). Safari pages: one read-only `do JavaScript`
  in Claude's tab (address, title, the same blanked source, visibility, the performance entries).
- **Linux** (FR-1444): `internal/agent` answers the tool before the toolset: the activity log's
  public events in the span and its call lines for the call ids.
- **Building the report** (FR-1448 to FR-1451): format 3 adds `calls`, `relay_log`, `parts`,
  `left_out`. Blanking: the values Claude passed as `code`, `password`, `check_code` (logins_fill,
  any tool) are collected from the calls' arguments and replaced by `(blanked)` everywhere in the
  report's JSON text; then each machine name (longest first), the account's email and the
  relay's public host are replaced by labels. Size: sealed size checked against 5 MB; over it,
  drop answers of the oldest calls, then oldest log lines, then cut page sources, until it fits.
  A small version (format 3 without calls, logs, parts; `left_out` says so) is sealed with it and
  kept in the outbox's new column `small`; an intake's 413 sends the small one once.
- **The intake** (FR-1455, FR-1456): `reports.MaxSealed` 5 MB; per-sender bytes per hour (50 MB)
  beside the count; total stored bytes (5 GB) beside `MaxReports`; both 429/503.
- **The developer** (FR-1452): `latchkey-reports list` prints each report's id, time, summary,
  client, machines and how many calls and pages it holds; `show <id> [-out dir]` writes
  `report.json`, `calls/NNN-tool.json`, images as `calls/NNN-k.png|jpg`, `pages/<n>.html`,
  `pages/<n>.json`, `logs/*.txt`, in a new folder under the system's temporary folder
  (`$TMPDIR/latchkey-report-…`, the session's scratch folder), every file written through an
  `os.Root` at it, so no name a report holds can leave it; it refuses a folder inside a git work
  tree.
- **Tests**: relay: a real MCP client files a report after browser-like and logins_fill calls
  against a stand-in machine; the opened report holds every call, the relay log, the part; the
  code is nowhere; a stand-in that never answers is listed after 10 s (short in the test); a
  5 MB budget trims oldest first; 413 sends the small one. Intake: 5 MB accepted, byte limits.
  Linux: the part. Mac (GitHub's runner): the record from a served page (a request, an error,
  visibility), the snapshot blanks a typed field and a hidden field, nothing on disk, gone at
  close; the part's JSON; the special tool never reaches the registry.

## Confirmation

The tests that validate the requirements it cites:

- `linux/internal/agent/reportpart_test.go`
- `macos/Tests/ReportPartTests.swift`
- `relay/agentproto/reportpart_test.go`
- `relay/cmd/latchkey-reports/show_test.go`
- `relay/internal/intake/intake_test.go`
- `relay/internal/mcpserver/fullreport_internal_test.go`
- `relay/internal/mcpserver/fullreport_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
