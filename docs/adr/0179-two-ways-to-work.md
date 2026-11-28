# 0179. Two ways to work (spec: the maintainer's choices)

- Status: accepted
- Date: 2026-11-25
- Alias: plan 016 D6 (`specs/016-test-strategy/plan.md`, "D6. Two ways to work (spec: the maintainer's choices)")

## Context and problem

Decision D6 of spec 016's plan (Test strategy and two ways to work); requirements in
[requirements/test-strategy.md](../requirements/test-strategy.md). Requirement IDs it cites: none current.
The design it belongs to: [design/test-strategy.md](../design/test-strategy.md).

## Decision


- CLAUDE.md "Two ways to work" (done 2026-11-26); `docs/cloud-sessions.md` lost the `shell_run`
  build route, the updater requests and the screenshots.
- The session-start hook also speaks to a local session: "local session: after building the Mac
  app, run `make sandbox`" (a line, tested in scripts/tests/hooks_test.sh).

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
