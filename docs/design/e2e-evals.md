# End-to-end tests and evals: design

GOVERNS: `relay/cmd/e2e/` `relay/e2e/` `.github/workflows/e2e.yml`

Spec 015's plan (migrated from `specs/015-e2e-evals/plan.md`, titled "Spec 015 plan: end-to-end tests and evals — HOW"). What it must do:
[requirements/e2e-evals.md](../requirements/e2e-evals.md). Each decision Dn is an ADR, linked
where the decision stood.

Status: Approved on 2026-11-24; being built (spec 015's task list (in git history; open items are GitHub issues)). Requirements: `docs/requirements/e2e-evals.md`. Findings and the
low-level choices Claude made: `docs/research/2026-11-24-e2e-evals.md`. Formats: `docs/design/contracts/task-format.md`,
`docs/design/contracts/eval-result.md`.

## Shape

```
Per pull request (GitHub, reported)                Weekly (started by hand, any clone)
  e2e.yml                                            macos/scripts/weekly-eval.sh
   ├─ pick: changed paths → capabilities              ├─ tart clone latchkey-eval → run copy
   ├─ e2e-linux (ubuntu): relay + Linux program        ├─ inside the copy:
   │    real MCP client, toolsnaps relay/linux         │    newest signed release, private relay,
   └─ e2e-mac (macos-26): app capabilities + relay     │    checks (all), ~20 tasks × 3 with
        real MCP client, local pages, toolsnaps mac    │    Claude Code (Sonnet, ≤ 1 hour)
                                                       ├─ results file in the clone (always),
                                                       │  sealed to the intake with --send
                                                       └─ tart delete the copy
the maintainer's cloud session start: no sent result this week? → one line: what to run.
```

## Decisions

### D1. One program, `relay/cmd/e2e` (FR-1500 to FR-1506, FR-1515 to FR-1526)

Decision record: [ADR 0165](../adr/0165-one-program-relay-cmd-e2e.md).

### D2. Picking what runs (FR-1500, FR-1502, FR-1504)

Decision record: [ADR 0166](../adr/0166-picking-what-runs.md).

### D3. The per-pull-request workflow (FR-1501 to FR-1506)

Decision record: [ADR 0167](../adr/0167-the-per-pull-request-workflow.md).

### D4. Tool snapshots (FR-1504)

Decision record: [ADR 0168](../adr/0168-tool-snapshots.md).

### D5. The weekly run (FR-1510 to FR-1517)

Decision record: [ADR 0169](../adr/0169-the-weekly-run.md).

### D6. The prepared image (FR-1512, FR-1513)

Decision record: [ADR 0170](../adr/0170-the-prepared-image.md).

### D7. Results and the reminder (FR-1511, FR-1530 to FR-1533)

Decision record: [ADR 0171](../adr/0171-results-and-the-reminder.md).

### D8. Tasks (FR-1520 to FR-1526)

Decision record: [ADR 0172](../adr/0172-tasks.md).

### D9. Releases and the requester's conditions (FR-1540, FR-1541)

Decision record: [ADR 0173](../adr/0173-releases-and-the-requesters-conditions.md).

## Milestones (in dependency order)

1. Shared start-up in `relay/internal/e2e`, `e2e pick` with its map, `e2e snap` with the relay
   and Linux snapshots, `e2e.yml` with `e2e-linux` (D1 to D4).
2. `E2EHostTests`, `e2e mac` with its checks and the Mac snapshots, `e2e-mac` (D3, D4).
3. `e2e fixture` and the task format, tried on GitHub's macOS runner for files and the browser
   (D8).
4. `e2e prepare`, `eval-image.sh` and weekly-eval.sh, then the one-time image setup (D5, D6).
5. Sealed results, `latchkey-reports evals`, the session-start step (D7).
6. The task set, held-out and planted-instruction tasks (D8); docs (D9).

## Steps only a person at the Mac can do (all together, once)

1. Run `macos/scripts/eval-image.sh` in Terminal from the clone (about 30 minutes, mostly
   downloads). When it asks, run `claude setup-token` and paste the token at its password
   prompt (never into a chat). When the test Mac's window opens, click Connect and approve
   Latchkey's permissions (about 10 minutes).
Then each week, when a session says so: `macos/scripts/weekly-eval.sh --send`.

## Consistency check (CLAUDE.md step 3a)

- Every requirement has a mechanism: FR-1500 D2; FR-1501 D1, D3; FR-1502 D3; FR-1503 D3;
  FR-1504 D4; FR-1505 D3; FR-1506 D3; FR-1510 D5; FR-1511 D7; FR-1512 D5, D6; FR-1513 D6;
  FR-1514 D5; FR-1515 D5; FR-1516 D5; FR-1517 D5 (never called by a workflow); FR-1520 to
  FR-1526 D8 and the task contract; FR-1530 to FR-1533 D7 and the result contract; FR-1540,
  FR-1541 D9.
- No new message crosses the relay–Mac boundary: the checks use the existing MCP surface and
  agent protocol. No new pairing path: the Swift host test and the test Mac use the existing ones (research.md decisions 4, 4a).
- The intake (spec 014) is unchanged: results use its existing endpoint and 64 KB limit.
- Spec 001 FR-680 to FR-689 (traces) are unchanged: the copy's traces go with the copy.
- The regression-tests work (`docs/regression-coverage.md`) adds unit and CI tests; this spec
  adds end-to-end checks and Claude tasks, and FR-1525 links tasks to the same case ids. No
  overlap in files.

## Constitution check

- I (outbound only): the Mac app dials out to a relay on the same runner or inside the copy;
  nothing listens on the host Mac. Pass.
- II (fail fast): every check, task and the whole weekly run has a deadline; an offline-machine
  answer is itself checked. Pass.
- III (disabled means nonexistent): checked on both runners (a capability turned off vanishes
  from the list and the snapshot). Pass.
- IV (good citizen, never disturb): the test Mac runs without a window; nothing touches the maintainer's
  apps or data; the maintainer starts it himself. The image setup opens one VM window, once, when the maintainer
  asks for it. Pass.
- V (self-hostable): nothing in the product depends on these; GitHub and Tart are test tools.
  Pass.
- VI (store the minimum): results hold test data only; the copy and its traces are deleted.
  Pass.
- VII (test-first, real MCP client): this spec is that, end to end. Pass.
- VIII (simplicity): one new program (`relay/cmd/e2e`, D1), one workflow, two scripts, each named
  by requirements; no outside framework. Pass.
- IX (open source): no new dependency in the relay or app; Tart is a tool on the maintainer's Mac, not
  shipped (research.md). Pass.
- X (a tool reports; Claude judges): no tool changes; the judging is the eval's, on state, not a
  tool's. Pass.
