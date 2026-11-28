# 0105. Readiness for update rollback (FR-909)

- Status: accepted
- Date: 2026-10-31
- Alias: plan 009 D3 (`specs/009-easy-relay-setup/plan.md`, "D3. Readiness for update rollback (FR-909)")

## Context and problem

Decision D3 of spec 009's plan (Easy relay setup); requirements in
[requirements/easy-relay-setup.md](../requirements/easy-relay-setup.md). Requirement IDs it cites: FR-909.
The design it belongs to: [design/easy-relay-setup.md](../design/easy-relay-setup.md).

## Decision


- When `NOTIFY_SOCKET` is set (systemd, and Podman's Quadlet with `Notify=true`), the relay sends
  `READY=1` once its database is open and its listener accepts connections, and `STOPPING=1` on
  shutdown. A few lines over a Unix datagram socket; no library. `podman auto-update` restarts
  the unit with the new image and rolls back when the unit fails to become ready.
- Options were (a) sd_notify, chosen: works with Ubuntu 24.04's Podman 4.9; (b) Quadlet's
  `Notify=healthy` with the image's health check, which needs Podman 5; (c) nothing: a relay
  that crashes after starting would not be rolled back.

## Confirmation

The tests that validate the requirements it cites:

- `relay/internal/store/backup_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
