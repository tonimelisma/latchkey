# Contract: problem reports (spec 014) — draft

## Mac → relay: the setting (FR-1400, FR-1403)

The Mac's existing state message gains one field:

```json
{"type": "state", "...": "...", "share_reports": true}
```

`share_reports` absent means false. The relay stores it per account; false drops the account's
waiting reports (FR-1403).

## Relay → Mac: the operator's block (FR-1415a)

The welcome message gains `"reports_blocked": true` when the operator added the block; the app
then says this relay doesn't forward problem reports.

## Relay → intake (FR-1420)

`POST {FEEDBACK_INTAKE_URL}/v1/reports`
- Body: the 4 bytes `LKR1`, then `hpke.Seal(developerKey, HKDFSHA256, ChaCha20Poly1305,
  info="latchkey-report-v1", plaintext)`, KEM `MLKEM768X25519`; at most 5 MB (64 KB before 2026-11-25; an older intake answers 413 to a larger one and
  the relay then sends the report's small version, FR-1451).
- Proof of work: SHA-256 of (SHA-256 of the body, the hour, the nonce as 8 bytes big-endian)
  starts with 20 zero bits; the hour is the current or the previous UTC hour, written
  `2006-01-02T15Z`.
- Headers: `Latchkey-Work-Hour: <the hour>`, `Latchkey-Work-Nonce: <decimal>`.
- Answers: 202 `{"id": "<id>"}`; 400 malformed; 413 too big; 403 bad proof; 429 over the limit;
  503 full.

Plaintext (JSON):

```json
{
  "format": 2,
  "id": "fb_…",
  "at": "2026-11-24T05:45:16Z",
  "summary": "…", "details": "…",
  "client": "Anthropic/ClaudeAI",
  "relay_version": "…",
  "machines": [
    {"named": true, "kind": "mac", "version": "0.8.235", "system": "macOS 27.0.1", "screen": "locked"}
  ],
  "reporter": "3f9a0c1d2b4e5f60"
}
```

`id` (2026-11-24): the id the `feedback` tool gave Claude, so the user's chat and the developer's
list name the same report; the intake's own id (`rep_…`) only addresses the stored copy.

`machines` (format 2, 2026-11-24): each machine Claude named in the tool's `machines` argument,
`named: true`; when it named none (or only names that match no machine), every machine online
at the time, without `named`. Never a machine's name. Format 1 reports (before 2026-11-24) had
one machine's `machine_version`, `system` and `screen` at the top level instead, filled only
when Claude named it or it was the only machine; the developer's command reads both.

Format 3 (2026-11-25, FR-1440 to FR-1451) adds, after `reporter`:

```json
{
  "format": 3,
  "chat": {"sessions": 2, "from": "2026-11-25T03:10:00Z", "to": "2026-11-25T03:41:00Z"},
  "calls": [
    {"time": "…", "tool": "browser_act", "machine": "machine 1", "call_id": "call_…",
     "arguments": {…}, "result": [{"type": "text", "text": "…"}, {"type": "image", "data": "…", "mimeType": "image/jpeg"}],
     "is_error": false, "duration_ms": 1830, "outcome": "ok", "left_out": ""}
  ],
  "relay_log": ["2026-11-25T03:12:01.123Z WARN report not delivered status=503"],
  "parts": [
    {"machine": "machine 1", "answered": true, "note": "", "part": {…the machine's part…}}
  ],
  "left_out": ["the answers of 3 older calls (size)"]
}
```

`machines[i]` gains `"label": "machine 1"`, the name every other part of the report uses for it.
A call `left_out` "size" has no `result`. The small version (FR-1451) is format 3 without
`calls`, `relay_log` and `parts`, and with `left_out` saying why.

## Relay → machine: its part of a report (FR-1443 to FR-1445)

Only to a machine whose hello lists the feature `report_part`. An ordinary `call`, deadline
10 000 ms, tool `latchkey_report_part` (never in a machine's tool list: the relay refuses a
hello or tools message that offers it), arguments:

```json
{"report": "fb_…", "since": 1764040200000, "until": 1764042060000,
 "call_ids": ["call_…"], "pages": ["p4k2"], "max_bytes": 3500000}
```

The `result` has one text content whose text is the part's JSON, at most `max_bytes`:

```json
{
  "log": [{"time": "…", "category": "browser", "error": false, "text": "…"}],
  "calls": [{"call_id": "call_…", "time": "…", "tool": "…", "result": […], "is_error": false, "duration_ms": 0}],
  "pages": [{
    "name": "p4k2", "where": "own" | "safari", "address": "…", "title": "…",
    "source": "<html>…</html>", "source_cut": false,
    "cookies": ["name", …],
    "drawing": {"visibility": "visible", "hidden": false, "focus": false, "frames_half_second": 30,
                "window": "1280x800", "screen": "1512x982", "mac_locked": true, "display_asleep": false},
    "record": [{"time": "…", "kind": "load|request|error|rejection|blocked|visibility", "address": "…",
                "method": "GET", "status": 200, "type": "fetch", "ms": 120, "bytes": 5120, "text": "…"}],
    "record_dropped": 0,
    "screenshot": {"mimeType": "image/jpeg", "data": "<base64>"}
  }],
  "notes": ["page p9zz isn't open any more"]
}
```

A machine that can't give a part answers an error result with the reason; the relay lists it
with that note. Fields a machine doesn't have are left out (a Linux server has no `pages`).

## Developer → intake (FR-1423)

With `Authorization: Bearer <developer token>`:
- `GET /v1/reports` → `[{"id", "arrived"}]`, oldest first
- `GET /v1/reports/{id}` → the sealed bytes
- `DELETE /v1/reports/{id}` → 204; the report is gone, nothing kept (FR-1424)
