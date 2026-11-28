# 0124. Mac app (FR-1002, FR-1012)

- Status: accepted
- Date: 2026-10-31
- Alias: plan 010 D13 (`specs/010-multi-host/plan.md`, "D13. Mac app (FR-1002, FR-1012)")

## Context and problem

Decision D13 of spec 010's plan (Several machines and Linux servers); requirements in
[requirements/multi-host.md](../requirements/multi-host.md). Requirement IDs it cites: FR-1002, FR-1012, FR-054.
The design it belongs to: [design/multi-host.md](../design/multi-host.md).

## Decision


The app sends `kind: mac` and `name` (its Settings value, default the computer name) in hello and
shows `welcome.name`. Settings gets "Name shown to Claude"; changing it reconnects. The pairing
page's and FR-054 dialog's "replaces the current pairing" text goes ("adds this Mac to your
account"). Fixtures updated; patch version bumped.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/PairingTests.swift`
- `relay/internal/account/account_test.go`
- `relay/internal/mcpserver/machines_e2e_test.go`
- `relay/internal/store/store_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
