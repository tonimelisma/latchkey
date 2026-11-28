# 0109. The guide (FR-901, FR-902, FR-904, FR-905, FR-906, FR-910)

- Status: accepted
- Date: 2026-10-31
- Alias: plan 009 D7 (`specs/009-easy-relay-setup/plan.md`, "D7. The guide (FR-901, FR-902, FR-904, FR-905, FR-906, FR-910)")

## Context and problem

Decision D7 of spec 009's plan (Easy relay setup); requirements in
[requirements/easy-relay-setup.md](../requirements/easy-relay-setup.md). Requirement IDs it cites: FR-901, FR-902, FR-904, FR-905, FR-906, FR-910.
The design it belongs to: [design/easy-relay-setup.md](../design/easy-relay-setup.md).

## Decision


- `docs/setup-with-claude.md` (in the plugin from spec 011 until it was withdrawn, 2026-11-01) as drafted: Google Cloud's free e2-micro in us-central1-a (other
  US zones if unavailable), Ubuntu 24.04, a reserved static address, firewall open on 443 only,
  the relay's own Let's Encrypt certificate (TLS-ALPN on 443), name `<ip-with-dashes>.sslip.io`,
  Podman Quadlet with `AutoUpdate=registry` and `Notify=true`, `podman-auto-update.timer`, a $1
  budget alert, and the setup code from D1. Steps say what Claude says, runs, and checks.
- The guide is fetched by its public raw URL (the repository is public, 2026-10-31).

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
