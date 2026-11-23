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
report (FR-1411). It builds the report of FR-1412 from what Claude wrote, unchanged, seals it
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

The intake's container runs on pilvi beside the relay's, behind the same Caddy, at
`latchkey-feedback.melisma.net` (an A record to pilvi, made 2026-11-23), with Caddy's usual
certificate for that one name. Its deployment lives with pilvi's, in the private deployment
repository; this repository holds the program and its image workflow. The relays' default intake
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

## Constitution check

- I (no inbound to the Mac): unchanged; the Mac takes no part in delivery.
- II (fail fast): `feedback` answers at once; delivery runs in the background with limits.
- III (off is gone): FR-1401.
- IV (never disturb): nothing on the Mac's screen except the setting itself.
- V (self-hostable): relays and the intake are both self-hostable; operators choose where
  reports go.
- VI (store the minimum): no readable report anywhere but the developer's session; the relay
  holds sealed bytes for at most 7 days.
- VII (test-first): D6, written first.
- VIII (simplicity): one new small program; the standard library's HPKE.
- IX (open): no new dependencies.
