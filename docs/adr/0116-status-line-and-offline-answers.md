# 0116. Status line and offline answers (FR-1008, FR-1009; decided 2026-10-31: list the others)

- Status: accepted
- Date: 2026-10-31
- Alias: plan 010 D5 (`specs/010-multi-host/plan.md`, "D5. Status line and offline answers (FR-1008, FR-1009; decided 2026-10-31: list the others)")

## Context and problem

Decision D5 of spec 010's plan (Several machines and Linux servers); requirements in
[requirements/multi-host.md](../requirements/multi-host.md). Requirement IDs it cites: FR-1008, FR-1009.
The design it belongs to: [design/multi-host.md](../design/multi-host.md).

## Decision


`<name> (Mac): online · 64% battery, on battery power · keep-awake on` and
`<name> (Linux): online · up 12 days`. With more than one machine paired a second line:
`Other machines: homeserver (Linux, online), Old Mac (Mac, offline since 3:02 PM)`. Offline
answers start with the machine's name ("homeserver is offline. It shut down at …"); Linux
reasons: `user_quit` → "Latchkey was stopped", `system_shutdown` → "It shut down",
`user_disconnected` → removed. Timeouts and other texts say the name in place of "Your Mac".

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
