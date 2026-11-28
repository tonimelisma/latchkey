# 0115. Choosing the machine for a call (FR-1005, FR-1007, FR-1008)

- Status: accepted
- Date: 2026-10-31
- Alias: plan 010 D4 (`specs/010-multi-host/plan.md`, "D4. Choosing the machine for a call (FR-1005, FR-1007, FR-1008)")

## Context and problem

Decision D4 of spec 010's plan (Several machines and Linux servers); requirements in
[requirements/multi-host.md](../requirements/multi-host.md). Requirement IDs it cites: FR-1005, FR-1007, FR-1008.
The design it belongs to: [design/multi-host.md](../design/multi-host.md).

## Decision


The `forward` handler takes `machine` out of the arguments before forwarding (the agent never
sees it) and resolves:

1. Named: match an active device by name, case-insensitive, trimmed. Unknown → error "No machine
   called 'x'. Your machines: …". Known but its stored list lacks the tool (off, or the kind
   doesn't have it) → "x doesn't offer <tool>. It's offered by: …" (none → as if unknown tool).
2. Not named: the devices whose stored list has the tool. Exactly one online → it. One device in
   all (online or not) → it (its offline answer comes at once). Otherwise → "Several machines
   offer <tool>: a (Mac, online), b (Linux, offline since …). Name one with machine." No guess.
3. The call goes through the hub to that device as today (deadline, cancel, progress); audit
   names the device (already per device).

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
