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
  info="latchkey-report-v1", plaintext)`, KEM `MLKEM768X25519`; at most 64 KB.
- Proof of work: SHA-256 of (SHA-256 of the body, the hour, the nonce as 8 bytes big-endian)
  starts with 20 zero bits; the hour is the current or the previous UTC hour, written
  `2006-01-02T15Z`.
- Headers: `Latchkey-Work-Hour: <the hour>`, `Latchkey-Work-Nonce: <decimal>`.
- Answers: 202 `{"id": "<id>"}`; 400 malformed; 413 too big; 403 bad proof; 429 over the limit;
  503 full.

Plaintext (JSON):

```json
{
  "format": 1,
  "at": "2026-11-23T05:45:16Z",
  "summary": "…", "details": "…",
  "client": "Anthropic/ClaudeAI",
  "relay_version": "…", "machine_version": "…", "system": "macOS 27.0.1",
  "screen": "locked" ,
  "reporter": "3f9a0c1d2b4e5f60"
}
```

## Developer → intake (FR-1423)

With `Authorization: Bearer <developer token>`:
- `GET /v1/reports` → `[{"id", "arrived"}]`, oldest first
- `GET /v1/reports/{id}` → the sealed bytes
- `DELETE /v1/reports/{id}` → 204; the report is gone, nothing kept (FR-1424)
