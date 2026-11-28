# 0175. One end-to-end harness (FR-1603, FR-1604)

- Status: accepted
- Date: 2026-11-25
- Alias: plan 016 D2 (`specs/016-test-strategy/plan.md`, "D2. One end-to-end harness (FR-1603, FR-1604)")

## Context and problem

Decision D2 of spec 016's plan (Test strategy and two ways to work); requirements in
[requirements/test-strategy.md](../requirements/test-strategy.md). Requirement IDs it cites: FR-1603, FR-1604.
The design it belongs to: [design/test-strategy.md](../design/test-strategy.md).

## Decision


- `relay/internal/e2e` keeps the one start-up: private relay, sign-up, OAuth, pairing, the Go MCP
  client. `cmd/e2e` (`pick`, `relay`, `mac`, `sandbox`, `evals`) and `cmd/linuxcheck` use it.
- Removed: `cmd/localcheck` (real Claude against a pretend Mac: evals cover Claude),
  `cmd/maccheck` + `LiveRelayTests` (battery vs pmset, a tool off, a silent network cut,
  reconnect: move to the sandbox Mac checks, D3), `cmd/guidecheck` (the relay-setup guide: an
  eval task with its own fixture). `make claude-check`, `make mac-check` go with them.
- One place per behavior: tests that only restated tool names, descriptions and schemas are
  removed, and since 2026-11-26 the tool snapshots too (decided: "That's a stupid check. Remove
  it"), so no test pins a description; `PublicToolsTests` keeps the levels' effect on the tool
  list. "A capability
  turned off disappears" stays in the integration layer (`e2e relay`, `e2e mac`, linuxcheck) and
  the unit test of the gate.
- `ci.yml` runs on `pull_request` and on `push` to `main` only (today every push to a pull
  request runs it twice). Withdrawn 2026-11-26: having `relay-image.yml` and `linux-release.yml`
  wait for `ci.yml` (`workflow_run`) instead of testing again; it only saves Linux minutes after
  a merge, and `workflow_run` can't be tried before it is on main, so a mistake would stop
  releases.
- The Mac app's end-to-end check runs in `ci.yml`'s Mac jobs's job 3 on that job's build (was a
  fifth macOS job with its own build); job 3 picks its checks itself, and `shard-suites.py` gives job 3's programs ~105 s less and job 0's ~140 s (its unit tests; measured 2026-11-26).
  Its checks stay reported. (Its tool-snapshot comparison, briefly required on 2026-11-26, was
  removed with the snapshots the same day: the maintainer, "That's a stupid check. Remove it". No test
  pins a tool's description.)
- On main, `ci.yml`'s Mac jobs skips the tests when the merged tree is the one a pull request's
  `mac` job passed (an artifact `mac-tested-<tree>`, 7 days); it still builds in job 0 to save
  the compilation cache (decided 2026-11-26: "Skip if identical").

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
