# 0178. Retire the hand-run kits (FR-1609)

- Status: accepted
- Date: 2026-11-25
- Alias: plan 016 D5 (`specs/016-test-strategy/plan.md`, "D5. Retire the hand-run kits (FR-1609)")

## Context and problem

Decision D5 of spec 016's plan (Test strategy and two ways to work); requirements in
[requirements/test-strategy.md](../requirements/test-strategy.md). Requirement IDs it cites: FR-1609.
The design it belongs to: [design/test-strategy.md](../design/test-strategy.md).

## Decision


- macos/scripts/state-check/ (237 cases): each case maps to a sandbox check (scriptable end
  state), an eval task (needs Claude), or the requester's conditions (locked, lid closed, his accounts:
  a short checklist in `docs/screen-states.md`); `docs/regression-coverage.md` lists the mapping;
  then the folder goes. `docs/use-cases.md` (written by its report) becomes a plain doc.
- `macos/scripts/safari-check*`: Safari tabs move into the sandbox checks (Safari in the copy).
- CLAUDE.md's "Every issue becomes a regression test" names the layer instead of `cases.json`
  (done 2026-11-26).

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
