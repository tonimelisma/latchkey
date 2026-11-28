# 0106. A copy of the database before a schema change (FR-909)

- Status: accepted
- Date: 2026-10-31
- Alias: plan 009 D4 (`specs/009-easy-relay-setup/plan.md`, "D4. A copy of the database before a schema change (FR-909)")

## Context and problem

Decision D4 of spec 009's plan (Easy relay setup); requirements in
[requirements/easy-relay-setup.md](../requirements/easy-relay-setup.md). Requirement IDs it cites: FR-909.
The design it belongs to: [design/easy-relay-setup.md](../design/easy-relay-setup.md).

## Decision


- At start, when goose reports pending migrations, the relay writes `VACUUM INTO
  /data/backups/relay-<UTC date>-<from version>.db` first, keeps the newest three, and logs the
  file. Going back to an older image means stopping the relay and putting that copy in place
  (docs/self-hosting.md says how); the key file is unchanged by migrations.

## Confirmation

The tests that validate the requirements it cites:

- `relay/internal/store/backup_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
