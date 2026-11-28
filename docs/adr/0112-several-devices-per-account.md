# 0112. Several devices per account (FR-1001, FR-1002, FR-1011, FR-1012)

- Status: accepted
- Date: 2026-10-31
- Alias: plan 010 D1 (`specs/010-multi-host/plan.md`, "D1. Several devices per account (FR-1001, FR-1002, FR-1011, FR-1012)")

## Context and problem

Decision D1 of spec 010's plan (Several machines and Linux servers); requirements in
[requirements/multi-host.md](../requirements/multi-host.md). Requirement IDs it cites: FR-1001, FR-1002, FR-1011, FR-1012.
The design it belongs to: [design/multi-host.md](../design/multi-host.md).

## Decision


`devices` keeps one row per pairing; the "one active device" rule goes. New columns `kind`
(`mac` or `linux`, default `mac` for existing rows) and a unique index on `(user_id,
lower(name))` among active devices is enforced in code, not SQL (revoked rows keep old names).
Pairing adds a device and never revokes one (`revokeActiveMac` becomes `revokeDevice(id)` and
`revokeAllDevices` for account deletion). Names: the requested name, cleaned as today; if an
active device of the account already has it (case-insensitive), " 2", " 3", … is appended.
The hello may carry `name` (D3): the relay renames the device (same rule) and returns the name
it kept in `welcome.name`. Store functions: `ActiveDevices(userID)`, `RenameDevice`.
Callers of `ActiveDevice` (account page, notices, clients list, `maccheck`) loop over
`ActiveDevices`; `clients` lists and `notice`s go to every connected device that announced the
feature (Macs; the Linux program announces neither).

Account page: a "Your machines" list (name, Mac or Linux, online or last seen, versions) with a
Remove button per machine, posting `/account/machines/remove` with the device ID; the old
`/account/mac/revoke` route removes all (kept for old pages). Removal: revoke, event, close with
4002, tools re-synced.

## Confirmation

The tests that validate the requirements it cites:

- `relay/internal/account/account_test.go`
- `relay/internal/account/devicepair_test.go`
- `relay/internal/mcpserver/machines_e2e_test.go`
- `relay/internal/store/store_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
