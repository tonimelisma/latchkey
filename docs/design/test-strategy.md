# Test strategy and two ways to work: design

GOVERNS: `.github/workflows/ci.yml` `macos/scripts/`

Spec 016's plan (migrated from `specs/016-test-strategy/plan.md`, titled "Spec 016: Test strategy and two ways to work — HOW"). What it must do:
[requirements/test-strategy.md](../requirements/test-strategy.md). Each decision Dn is an ADR, linked
where the decision stood.

Status: for the maintainer's review (2026-11-26) before spec 016's task list (in git history; open items are GitHub issues). What and why: `docs/requirements/test-strategy.md`; evidence:
`docs/research/2026-11-25-test-strategy.md`.

## Shape

```
every change ─ cloud / local / CI ──── 1 Fast: Go + Swift unit, fake clocks, golden messages              (gates)
every PR ───── GitHub Linux + Mac ──── 2 Integration: one harness (relay/internal/e2e), real MCP client   (gates)
Mac build ──── local session ───────── 3 Sandbox Mac: Tart copy of latchkey-eval, the local build installed,
                                          every capability against the real apps with test data
tools changed ─ local session / hand ── 4 Evals: real Claude in the same sandbox, pass rates (reported)
the maintainer asks ──── the maintainer's Mac ──────────── 5 the requester's conditions: locked, lid closed, his accounts
```

## Decisions

### D1. Fast layer gates, on fake clocks (FR-1601, FR-1602)

Decision record: [ADR 0174](../adr/0174-fast-layer-gates-on-fake-clocks.md).

### D2. One end-to-end harness (FR-1603, FR-1604)

Decision record: [ADR 0175](../adr/0175-one-end-to-end-harness.md).

### D3. The sandbox Mac (FR-1605, FR-1606, FR-1607, FR-1610)

Decision record: [ADR 0176](../adr/0176-the-sandbox-mac.md).

### D4. Evals in the same sandbox (FR-1608)

Decision record: [ADR 0177](../adr/0177-evals-in-the-same-sandbox.md).

### D5. Retire the hand-run kits (FR-1609)

Decision record: [ADR 0178](../adr/0178-retire-the-hand-run-kits.md).

### D6. Two ways to work (spec: the maintainer's choices)

Decision record: [ADR 0179](../adr/0179-two-ways-to-work.md).

## Order

1. FR-1607 fix and test (small, a bug).
2. D2's `ci.yml` triggers and release workflows (fast win, no risk).
3. D1 fake clocks, then the gate (the maintainer's ruleset step at the end).
4. D2 harness consolidation and single pinning.
5. D3 sandbox (needs a local session on the Mac with Tart: the image once, the maintainer approves its
   permissions once).
6. D5 retirement, D4 evals on the sandbox.

Steps 1–4 run in cloud sessions; 5–6 need a local session.

## Constitution check

- I (no inbound): the sandbox's relay is on the host; the copy connects out. Pass.
- II (fail fast): the harness and every check have deadlines; fake clocks test them. Pass.
- III (disabled means nonexistent): checked in the integration layer and its unit test. Pass.
- IV (good citizen): the sandbox never touches the host's screen, apps or data; nothing runs
  on the maintainer's Mac unasked. Pass.
- V (self-hostable), VI (store the minimum), IX (open source): results stay in the clone; no
  private values in results or logs. Pass.
- VII (test-first on the contracts): the golden protocol messages stay in the gating layers.
  Pass.
- VIII (simplicity): seven harnesses to one, five hand kits retired, one place per behavior.
  Pass.
- X (a tool reports): no tool changes. Pass.
