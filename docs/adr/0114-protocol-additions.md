# 0114. Protocol additions (FR-1002, FR-1009, FR-1020)

- Status: accepted
- Date: 2026-10-31
- Alias: plan 010 D3 (`specs/010-multi-host/plan.md`, "D3. Protocol additions (FR-1002, FR-1009, FR-1020)")

## Context and problem

Decision D3 of spec 010's plan (Several machines and Linux servers); requirements in
[requirements/multi-host.md](../requirements/multi-host.md). Requirement IDs it cites: FR-1002, FR-1009, FR-1020.
The design it belongs to: [design/multi-host.md](../design/multi-host.md).

## Decision


`hello` gains optional `kind` (`mac` default, `linux`) and `name` (string, 1 to 100
characters after cleaning). `welcome` gains `name` (the name the relay kept) when the hello had
one. `state` gains optional `uptime_s` (Linux); a Linux agent sends the Mac-only fields with
fixed neutral values (`power_source` "unknown", `battery_percent` 0, `thermal_state` "nominal",
`keep_awake` "on", `charging`/`low_power_mode` false, `lid_closed` null), which the relay
ignores for `linux`. A tool list defining a top-level input property `machine`, or the tool name
`machines`, is a protocol violation (4005). New fixtures: `hello-linux.json`,
`welcome-name.json`, `state-linux.json`, invalid `tools-machine-property.json`,
`tools-machines-name.json`. Choice: fields on existing messages rather than new message types,
because every older peer ignores unknown fields while unknown types close the connection.

## Confirmation

The tests that validate the requirements it cites:

- `relay/internal/mcpserver/machines_e2e_test.go`
- `relay/internal/store/store_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
