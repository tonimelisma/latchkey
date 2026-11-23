# Spec 014 plan: problem reports to the developer — HOW

Draft for Toni's review; nothing here is built yet. Choices and options: `research.md`.

## D1. The setting (FR-1400 to FR-1403)

The Mac app's Settings gets "Share problem reports with Latchkey's developer" beside the
capabilities, Off by default, with the explanation of FR-1402 shown before it takes effect. The
app sends the account's choice to the relay in its state message (a new field, contract
`contracts/feedback-intake.md`), and the relay keeps one flag per account. A relay whose operator
added the block (FR-1415a) says so in its welcome, and the app says this relay doesn't forward
problem reports.

## D2. Asking Claude (FR-1401, FR-1405, FR-1406)

The relay builds its tool list and server instructions per account: with the flag off,
`feedback` and every mention of it are left out. With it on, the instructions keep today's
paragraph, and the relay appends one line to every error answer it passes to Claude (the
relay sees every answer, so no Mac change is needed).

## D3. Filing on the relay (FR-1410 to FR-1416)

`feedback` is answered by the relay as today, its description saying what must stay out of a
report (FR-1411). It builds the report of FR-1412 from what Claude wrote, unchanged, seals it with `crypto/hpke` to the configured developer key, finds the proof of
work, and stores only the sealed bytes in an outbox table (`id`, `sealed`, `created`, `tries`).
A sender goroutine posts each to the intake with backoff, deletes it on acceptance, and deletes
it after 7 days with a log line. The relay's own report table and the delivery to the Mac
(spec 001 FR-691 to FR-693) are removed; existing rows are deleted at upgrade.

Operator settings (environment): `FEEDBACK_INTAKE_URL` and `FEEDBACK_DEVELOPER_KEY` (base64
public key), both defaulting to Latchkey's developer (FR-1415); `FEEDBACK_BLOCK=1` adds the
operator's block (FR-1415a).

## D4. The intake (FR-1420 to FR-1425)

A Go program in `intake/` (its own module; `research.md`, "repository layout"), SQLite, one container, the relay's tooling (lint,
security checks, tests, signed image through a workflow like `relay-image.yml`):

- `POST /v1/reports`: body = sealed report; headers carry the proof-of-work nonce and hour.
  Refuses bodies over 64 KB, a bad proof, a body that doesn't parse as an HPKE message of the
  expected suite, or a sender over its hourly limit. Answers 202 with the report's id.
- `GET /v1/reports`, `GET /v1/reports/{id}`, `DELETE /v1/reports/{id}`: only with the
  developer's token (bearer); sealed bytes out. The agent deletes a report once it is
  dispositioned (FR-1424): the fix, its regression case, or the reason in the agent's reply is the
  record, nothing stays in the intake.

## D4a. Names and hosting (FR-1426)

Order matters, so no relay is ever unreachable and no old name sends reports to a relay:
1. The hosted relay gets its new, hard-to-guess name (a DNS record, its certificate, its own
   settings; in the private repository that holds its deployment), and both names answer for a
   while.
2. Everything that points at the relay moves to the new name: Toni's Claude connector, the Mac
   app's relay address (`Local.xcconfig`, never committed), purkki's Linux program.
3. The latchkey name moves to the intake on pilvi (its container beside the relay's, behind the
   same reverse proxy, with its own certificate).
4. Only then does the relays' default intake address, the latchkey name, go into this repository.

Toni's steps: the DNS records, and changing the connector's address in Claude's settings.

## D5. The developer's agent (FR-1430, FR-1431)

- The token: given to the cloud environment with `request_credential` for the intake's host, so
  the session's network proxy adds it and the agent never sees it.
- The private key: a variable of Toni's personal cloud environment; `intake open` (a small
  command of the intake program, `go run ./intake/cmd/open`) reads sealed reports on stdin and
  prints them, only inside the session.
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
