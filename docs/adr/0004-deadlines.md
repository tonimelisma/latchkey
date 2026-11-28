# 0004. Deadlines

- Status: accepted
- Date: 2026-10-19
- Alias: plan 001 D3 (`specs/001-core/plan.md`, "D3. Deadlines")

## Context and problem

Decision D3 of spec 001's plan (Core: connect Claude to the Mac); requirements in
[requirements/core.md](../requirements/core.md). Requirement IDs it cites: FR-011.
The design it belongs to: [design/core.md](../design/core.md).

## Decision

Serves FR-011, Constitution II.
- Default deadline 10 s per call. A tool may declare a longer one in its metadata, capped at 60 s.
  `battery_status` uses 5 s. The declared number is clamped to 1 ms to 60 s before it becomes a
  duration, so a huge or non-finite value from the Mac can't wrap around to a negative deadline
  (security review, 2026-10-25).
- On deadline: the relay returns a timeout error, sends `cancel` to the Mac, and drops any late
  result.
- [NEEDS CLARIFICATION: Claude's hosted client timeout is undocumented. Measure it in M4 and keep
  our cap below it.]

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
