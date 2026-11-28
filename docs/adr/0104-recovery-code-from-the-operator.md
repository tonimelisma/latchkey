# 0104. Recovery code from the operator (FR-914)

- Status: accepted
- Date: 2026-10-31
- Alias: plan 009 D2 (`specs/009-easy-relay-setup/plan.md`, "D2. Recovery code from the operator (FR-914)")

## Context and problem

Decision D2 of spec 009's plan (Easy relay setup); requirements in
[requirements/easy-relay-setup.md](../requirements/easy-relay-setup.md). Requirement IDs it cites: FR-914, FR-631.
The design it belongs to: [design/easy-relay-setup.md](../design/easy-relay-setup.md).

## Decision


- New operator command `relay account recovery-code <email>`, run inside the container (on the
  default host: `gcloud compute ssh` then `sudo podman exec latchkey-relay /relay account
  recovery-code <email>`). It makes the same kind of code the relay emails for "Lost your
  passkey?" today, stores it the same way (hashed, single use), and prints it; lifetime 1 hour
  instead of the emailed code's 15 minutes, since it passes through a person and Claude Code.
- Without an email server, "Lost your passkey?" asks for the email address and goes straight to
  the code step ("Enter the recovery code you were given"), sending nothing. The existing code
  step then lets the person make a new passkey for the same account, as email recovery does
  (plan 001 D5): the Mac's pairing and the records stay; the old passkeys stop working and
  Claude's apps sign in again.
- Using it is recorded as recovery is today (event `account_recovered`, FR-631), and the Mac is
  told on its next connection (existing notice).

## Confirmation

The tests that validate the requirements it cites:

- `relay/internal/account/events_test.go`
- `relay/internal/hub/audit_test.go`
- `relay/internal/operator/operator_test.go`
- `relay/internal/server/events_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
