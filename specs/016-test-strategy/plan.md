# Spec 016: Test strategy and two ways to work — HOW

Status: for Toni's review (2026-11-26) before `tasks.md`. What and why: `spec.md`; evidence:
`research.md`.

## Shape

```
every change ─ cloud / local / CI ──── 1 Fast: Go + Swift unit, fake clocks, golden messages, snapshots   (gates)
every PR ───── GitHub Linux + Mac ──── 2 Integration: one harness (relay/internal/e2e), real MCP client   (gates)
Mac build ──── local session ───────── 3 Sandbox Mac: Tart copy of latchkey-eval, the local build installed,
                                          every capability against the real apps with test data
tools changed ─ local session / hand ── 4 Evals: real Claude in the same sandbox, pass rates (reported)
Toni asks ──── Toni's Mac ──────────── 5 Toni's conditions: locked, lid closed, his accounts
```

## Decisions

### D1. Fast layer gates, on fake clocks (FR-1601, FR-1602)

- Swift: the deadline code takes an injected clock (Swift's `Clock` protocol: `ContinuousClock`
  in the app, a test clock that tests advance by hand). Every test in
  `macos/scripts/timing-suites.txt` and `quiet-suites.txt` moves to it; what still needs real
  time (a WebKit page's own events) asserts on order and outcome, never on a duration. The lists
  `timing-suites.txt` and `quiet-suites.txt` go once empty.
- Go: deadline tests use `testing/synctest` (Go 1.25+, the module is on 1.27) instead of
  sleeps.
- `mac-build.yml`: `continue-on-error` comes off the test steps once main is green three runs in
  a row; then the four test jobs become required checks in the ruleset `main` (a setting only
  Toni can change: one `gh` command from a local session, prepared for him).
- Options weighed: (a) longer limits on CI only (hides real regressions, still flaky); (b)
  quarantine the ~30 (leaves deadlines untested); (c) fake clocks (deterministic, fast). Chose (c).

### D2. One end-to-end harness (FR-1603, FR-1604)

- `relay/internal/e2e` keeps the one start-up: private relay, sign-up, OAuth, pairing, the Go MCP
  client. `cmd/e2e` (`pick`, `relay`, `mac`, `sandbox`, `evals`) and `cmd/linuxcheck` use it.
- Removed: `cmd/localcheck` (real Claude against a pretend Mac: evals cover Claude),
  `cmd/maccheck` + `LiveRelayTests` (battery vs pmset, a tool off, a silent network cut,
  reconnect: move to the sandbox Mac checks, D3), `cmd/guidecheck` (the relay-setup guide: an
  eval task with its own fixture). `make claude-check`, `make mac-check` go with them.
- One place per behavior: tool names, descriptions and schemas only in `relay/e2e/toolsnaps`;
  `PublicToolsTests` keeps only what snapshots don't show (a tool off is absent), and the
  regression tests that pin description sentences are replaced by their snapshot. "A capability
  turned off disappears" stays in the integration layer (`e2e relay`, `e2e mac`, linuxcheck) and
  the unit test of the gate.
- `ci.yml` runs on `pull_request` and on `push` to `main` only (today every push to a pull
  request runs it twice); `relay-image.yml` and `linux-release.yml` wait for `ci.yml`'s result on
  that commit (`workflow_run`) instead of testing again.

### D3. The sandbox Mac (FR-1605, FR-1606, FR-1607, FR-1610)

- `make sandbox` in `macos/` (a local session; any Apple silicon Mac with Tart):
  1. builds the Release app from the working tree, signed with the developer's Apple
     Development certificate (`Local.xcconfig`), so its signature matches the image's grants;
  2. starts a copy of the `latchkey-eval` image without a window (`tart run --no-graphics`), or
     reuses the one this session started (kept up until the session ends or `make sandbox-stop`);
  3. installs the build in the copy, replacing the last one (`eval-lib.sh`'s `install_latchkey`
     gets a local-build path beside the newest-release path);
  4. seeds test data (`cmd/e2e fixture`: a test folder, notes, events, reminders, contacts, a
     served sign-in page; Messages and Mail from a test account where the image has one, else
     skipped with the reason);
  5. runs `cmd/e2e sandbox`: the real MCP client through a private relay on the host, against
     the installed app, every capability's checks plus the moved `maccheck` checks, compared
     with the snapshots; writes `e2e-results/sandbox-<build>-<time>.json`.
  First run under 5 minutes (build ~1.5, start ~1, checks ~2); later runs reuse the copy: under
  2 minutes.
- Never touches the host's Latchkey, data or screen: the copy has no shared folders, no window,
  its own relay; nothing of the Mac goes in (Constitution IV, FR-1606).
- The same command from GitHub's Mac runner is not possible (no nested virtualization there);
  `e2e mac` stays the per-PR Mac check.
- FR-1607, first, with its regression test: the Debug product is named "Latchkey Dev.app"
  (`PRODUCT_NAME` per configuration), `AppLocation.needsMove` returns false for any build whose
  bundle ID isn't the release one, and `offerMove` refuses to replace an app with a different
  bundle ID. Test: `AppLocationTests` fails on main (a dev bundle outside DerivedData asks to
  move) and passes with the fix.
- Options weighed for where (research §3): a separate macOS user (takes the screen for
  unlocked runs), a dev copy in Toni's account (his real data), Tart (isolated). Toni chose Tart.

### D4. Evals in the same sandbox (FR-1608)

- `make evals` = `weekly-eval.sh` renamed, on the sandbox of D3, with the local build or
  `--release`; 20 tasks × 3, scored on the end state, pass^3 per task, compared with the last
  run (`latchkey-reports evals`). Run by a local session when a tool, its description or its
  answers change, and on a new Claude model; reported, never a gate.

### D5. Retire the hand-run kits (FR-1609)

- `macos/scripts/state-check/` (237 cases): each case maps to a sandbox check (scriptable end
  state), an eval task (needs Claude), or Toni's conditions (locked, lid closed, his accounts:
  a short checklist in `docs/screen-states.md`); `docs/regression-coverage.md` lists the mapping;
  then the folder goes. `docs/use-cases.md` (written by its report) becomes a plain doc.
- `macos/scripts/safari-check*`: Safari tabs move into the sandbox checks (Safari in the copy).
- CLAUDE.md's "Every issue becomes a regression test" names the layer instead of `cases.json`
  (done 2026-11-26).

### D6. Two ways to work (spec: Toni's choices)

- CLAUDE.md "Two ways to work" (done 2026-11-26); `docs/cloud-sessions.md` lost the `shell_run`
  build route, the updater requests and the screenshots.
- The session-start hook also speaks to a local session: "local session: after building the Mac
  app, run `make sandbox`" (a line, tested in `scripts/tests/hooks_test.sh`).

## Order

1. FR-1607 fix and test (small, a bug).
2. D2's `ci.yml` triggers and release workflows (fast win, no risk).
3. D1 fake clocks, then the gate (Toni's ruleset step at the end).
4. D2 harness consolidation and single pinning.
5. D3 sandbox (needs a local session on the Mac with Tart: the image once, Toni approves its
   permissions once).
6. D5 retirement, D4 evals on the sandbox.

Steps 1–4 run in cloud sessions; 5–6 need a local session.

## Constitution check

- I (no inbound): the sandbox's relay is on the host; the copy connects out. Pass.
- II (fail fast): the harness and every check have deadlines; fake clocks test them. Pass.
- III (disabled means nonexistent): checked in the integration layer and its unit test. Pass.
- IV (good citizen): the sandbox never touches the host's screen, apps or data; nothing runs
  on Toni's Mac unasked. Pass.
- V (self-hostable), VI (store the minimum), IX (open source): results stay in the clone; no
  private values in results or logs. Pass.
- VII (test-first on the contracts): golden messages and snapshots stay in the gating layers.
  Pass.
- VIII (simplicity): seven harnesses to one, five hand kits retired, one place per behavior.
  Pass.
- X (a tool reports): no tool changes. Pass.
