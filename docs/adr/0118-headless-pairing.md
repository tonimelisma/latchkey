# 0118. Headless pairing (FR-1022; RFC 8628's shape)

- Status: accepted
- Date: 2026-10-31
- Alias: plan 010 D7 (`specs/010-multi-host/plan.md`, "D7. Headless pairing (FR-1022; RFC 8628's shape)")

## Context and problem

Decision D7 of spec 010's plan (Several machines and Linux servers); requirements in
[requirements/multi-host.md](../requirements/multi-host.md). Requirement IDs it cites: FR-1022.
The design it belongs to: [design/multi-host.md](../design/multi-host.md).

## Decision


Endpoints, sharing the pairing endpoints' per-address limit:

- `POST /pair/device` {name, kind, public_key} → {device_code, user_code, verification_uri,
  interval 5, expires_in 600}. `user_code`: 8 letters from BCDFGHJKLMNPQRSTVWXZ, shown
  `ABCD-EFGH`. Both stored hashed (table `device_pairings`). No `verification_uri_complete`
  (security review, 2026-10-31): a link carrying the code would let someone who started a pairing
  on their own machine get it approved with one click from a link they send.
- `GET /link` (signed in): the code form (a code in the address is ignored). `POST /link` with
  the typed code: a confirmation naming the machine and kind, when it asked, that the machine
  chose its name, and the warning "Only connect a machine you just set up yourself". `POST /link`
  with `confirm` (CSRF) approves: creates the device (D1 naming) with the key given at the start,
  marks the row. Wrong codes: 10 per account per 10 minutes, then the form refuses for the rest of
  the window.
- `POST /pair/device/token` {device_code} → `400 {"error":"authorization_pending"}`,
  `"slow_down"` (polled faster than the interval), `"expired_token"`, or `200 {"device_id",
  "name"}` once; rows deleted an hour after expiry.

## Confirmation

The tests that validate the requirements it cites:

- `relay/internal/account/devicepair_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
