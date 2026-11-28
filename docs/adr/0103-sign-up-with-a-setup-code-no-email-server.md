# 0103. Sign-up with a setup code, no email server (FR-907, FR-908)

- Status: accepted
- Date: 2026-10-31
- Alias: plan 009 D1 (`specs/009-easy-relay-setup/plan.md`, "D1. Sign-up with a setup code, no email server (FR-907, FR-908)")

## Context and problem

Decision D1 of spec 009's plan (Easy relay setup); requirements in
[requirements/easy-relay-setup.md](../requirements/easy-relay-setup.md). Requirement IDs it cites: FR-907, FR-908.
The design it belongs to: [design/easy-relay-setup.md](../design/easy-relay-setup.md).

## Decision


- New setting `SETUP_CODE`. `SMTP_HOST` and `SMTP_FROM` stop being required when `SETUP_CODE` is
  set; the relay refuses to start with neither (it would have no way to let anyone in).
- With `SETUP_CODE` set and no account yet, the sign-up page asks for an email address and the
  code. The code is compared in constant time; a match counts as a verified email (it takes the
  place of the emailed code, `authCode`), and the passkey ceremony follows as today. Wrong codes
  go through the existing abuse limits (per address and per visitor).
- Once any account exists, the code no longer opens sign-up, and the page says sign-up is
  closed. With an email server also configured, the relay works as today for everyone else
  (`ALLOWED_EMAILS` decides who).
- The code is a setting, not stored: the user table is the record that it was used. No schema
  change. Options were (a) this; (b) a stored one-time code, which needs a table and a way to
  make it; (c) first visitor wins (Immich), refused: a fresh relay on a public address could be
  claimed by anyone who finds it first.

## Confirmation

The tests that validate the requirements it cites:

- `relay/cmd/relay/config_test.go`
- `relay/internal/account/setupcode_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
