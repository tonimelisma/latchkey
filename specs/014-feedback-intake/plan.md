# Spec 014 plan: problem reports to the developer — HOW

Built 2026-11-23. Choices and options: `research.md`; tasks: `tasks.md`.

## D1. The setting (FR-1400 to FR-1403)

The Mac app's Settings gets "Share problem reports with Latchkey's developer" beside the
capabilities, Off by default, with the explanation of FR-1402 shown before it takes effect. The
app sends the account's choice to the relay in its state message (a new field, contract
`contracts/feedback-intake.md`), and the relay keeps one flag per account. A relay whose operator
added the block (FR-1415a) says so in its welcome, and the app says this relay doesn't forward
problem reports.

## D2. Asking Claude (FR-1401, FR-1405, FR-1406)

The relay builds its tool list and server instructions per account: with the flag off,
`feedback` and every mention of it are left out (the general instructions no longer mention it
at all; the tool's description carries the guidance, FR-1405). With it on, the relay appends one
line to every error answer it passes to Claude (the relay sees every answer, so no Mac change is
needed). A machine whose `share_reports` changes makes the relay re-sync the tool list.

## D3. Filing on the relay (FR-1410 to FR-1416)

`feedback` is answered by the relay as before, its description saying what must stay out of a
report (FR-1411) and asking Claude to name every machine involved in its `machines` argument
(FR-1410a; the older single `machine` is still accepted from chats that started before). The
machines part (`reportMachines`) matches the names to the account's machines, case-insensitively,
and gives each one's kind, versions and screen state, never its name; with no name that matches,
every online machine (FR-1412, report format 2, 2026-11-24). It builds the report of FR-1412 from what Claude wrote, unchanged, seals it
with `crypto/hpke` to the configured developer key (package `relay/reports`), and stores only the
sealed bytes in the `report_outbox` table. A sender goroutine finds each report's proof of work
for the current hour, posts it to the intake with backoff, deletes it on acceptance or a lasting
refusal, and deletes it after 7 days with a log line. Before each send it checks again that the
account still shares (security review 2026-11-23), so a report filed just before sharing went
off, or for a machine since removed, never leaves. The relay's old report table and the delivery
to the Mac (spec 001 FR-691 to FR-693, withdrawn) are removed; migration 00015 drops the old rows.

Operator settings (environment): `REPORTS_INTAKE_URL` and `REPORTS_DEVELOPER_KEY` (base64 public
key), both defaulting to Latchkey's developer (`relay/reports/defaults.go`, FR-1415);
`REPORTS_BLOCK=1` adds the operator's block (FR-1415a).

## D4. The intake (FR-1420 to FR-1425)

A Go program in the relay's module (`relay/cmd/latchkey-intake`, `relay/internal/intake`;
`research.md`, "repository layout"), SQLite, one container (`relay/Dockerfile.intake`), with the
relay's lint, security checks and tests, published and signed by `relay-image.yml` as
`ghcr.io/tonimelisma/latchkey-intake`:

- `POST /v1/reports`: body = sealed report; headers carry the proof-of-work nonce and hour.
  Refuses bodies over 64 KB, a bad proof, a body without the report's shape (the `LKR1` mark and
  at least the HPKE encapsulation and tag), a sender over its hourly limit, or more than 10,000
  waiting reports. Answers 202 with the report's id.
- `GET /v1/reports`, `GET /v1/reports/{id}`, `DELETE /v1/reports/{id}`: only with the
  developer's token (bearer); sealed bytes out. The agent deletes a report once it is
  dispositioned (FR-1424): the fix, its regression case, or the reason in the agent's reply is the
  record, nothing stays in the intake.

## D4a. Name and hosting (FR-1426)

The intake runs on the developer's own server, which is run outside this repository, at
`latchkey-feedback.melisma.net` (its DNS record made 2026-11-23), with an ordinary certificate
for that one name. Its deployment lives with that server's, in a private repository; this repository holds the program and its image workflow. The relays' default intake
address is that name.

## D5. The developer's agent (FR-1430, FR-1431)

- The token: given to the cloud environment with `request_credential` for the intake's host, so
  the session's network proxy adds it and the agent never sees it.
- The private key: `LATCHKEY_REPORTS_KEY`, a variable of Toni's personal cloud environment (Toni
  sets it; it is written nowhere else). `latchkey-reports list` (`relay/cmd/latchkey-reports`)
  fetches the open reports and prints them opened, only inside the session; `latchkey-reports
  delete <id>` deletes a dispositioned one.
- `docs/cloud-sessions.md` and CLAUDE.md's session start change from "list the Mac's Feedback
  folder" to "count open reports at the intake".

## D6. Tests

- Relay: tool absent and no line with the flag off; the description names what stays out; the outbox never holds
  plaintext (the database is searched for the report's words); retry, acceptance, and the 7-day
  drop; turning sharing off drops waiting reports.
- Intake: refuses big, unproven, malformed, and over-limit bodies; the developer endpoints need
  the token; nothing it stores opens without the key.
- End to end in tests: a relay and an intake in one process, a report filed through a real MCP
  client, opened with the test key.
- Mac: the setting and its explanation; the state message carries it.

## D7. Everything for that chat (FR-1440 to FR-1456; 2026-11-25)

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
  `error`, `unhandledrejection`, `securitypolicyviolation` and `visibilitychange` through a
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
  `pages/<n>-record.json`, `logs/*.txt`; the default folder is the session's scratch folder
  (`$TMPDIR/latchkey-report-<id>`), never inside the repository (it refuses a folder inside a git
  work tree).
- **Tests**: relay: a real MCP client files a report after browser-like and logins_fill calls
  against a stand-in machine; the opened report holds every call, the relay log, the part; the
  code is nowhere; a stand-in that never answers is listed after 10 s (short in the test); a
  5 MB budget trims oldest first; 413 sends the small one. Intake: 5 MB accepted, byte limits.
  Linux: the part. Mac (GitHub's runner): the record from a served page (a request, an error,
  visibility), the snapshot blanks a typed field and a hidden field, nothing on disk, gone at
  close; the part's JSON; the special tool never reaches the registry.

## Constitution check

- I (no inbound to the Mac): unchanged; the Mac takes no part in delivery.
- II (fail fast): `feedback` answers within 10 s at most (machines' parts, D7); delivery runs in the background with limits.
- III (off is gone): FR-1401.
- IV (never disturb): nothing on the Mac's screen except the setting itself.
- V (self-hostable): relays and the intake are both self-hostable; operators choose where
  reports go.
- VI (store the minimum): no readable report anywhere but the developer's session; the relay
  holds sealed bytes for at most 7 days; page records and the relay's log ring are memory only.
- VII (test-first): D6, written first.
- VIII (simplicity): one new small program; the standard library's HPKE.
- IX (open): no new dependencies.
