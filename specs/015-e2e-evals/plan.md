# Spec 015 plan: end-to-end tests and evals — HOW

Status: Approved by Toni (2026-11-24); being built (`tasks.md`). Requirements: `spec.md`. Findings and the
low-level choices Claude made: `research.md`. Formats: `contracts/task-format.md`,
`contracts/eval-result.md`.

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
Toni's cloud session start: no sent result this week? → one line: what to run.
```

## Decisions

### D1. One program, `relay/cmd/e2e` (FR-1500 to FR-1506, FR-1515 to FR-1526)
Subcommands: `pick` (paths to capabilities), `checks` (the deterministic end-to-end checks),
`snap` (tool snapshots), `weekly` (checks plus Claude tasks, inside the test Mac), `fixture`
(set up, check and clean test data on macOS). It reuses what the existing checks have: the
private relay start-up and headless-Chrome sign-up (`relay/internal/e2e`), the Go MCP client,
Claude Code non-interactive (`relay/internal/e2e/claude.go`, extended to read stream-json). The
existing `localcheck`, `linuxcheck`, `maccheck` stay as they are; their shared start-up moves
into `relay/internal/e2e` where it isn't already (Constitution VIII: one new program, no
second harness).

### D2. Picking what runs (FR-1500, FR-1502, FR-1504)
`relay/e2e/capabilities.json` maps path globs to capabilities and each capability to its
checks; shared paths (`relay/internal/server`, `relay/agentproto`, `macos/App/AgentProtocol.swift`,
`macos/App/AppModel.swift`, the workflow and `relay/cmd/e2e` themselves, …) select all. A
changed tool snapshot selects its capability. `e2e pick` reads `git diff --name-only` against
the pull request's base and prints the selection; a test fails when a source file under
`macos/App/`, `linux/` or `relay/internal/` matches no glob, so new code can't fall outside the
map.

### D3. The per-pull-request workflow (FR-1501 to FR-1506)
New `.github/workflows/e2e.yml`, on every pull request and push to main, read-only token, no
secrets (FR-1503). Two jobs that always run and pass at once when `pick` selects nothing for
them (research.md decision 6):
- `e2e-linux` (ubuntu-latest): the relay's own tools (`machines`, `feedback`, offline answers)
  with a pretend Mac, and the real Linux program in its systemd container (as `linuxcheck`):
  shell, files, pause, a capability turned off disappears (Constitution III).
- `e2e-mac` (macos-26): the app's real capabilities served by a Swift test the app hosts
  (`macos/Tests/E2EHostTests.swift`, the way `LiveRelayTests` serves `maccheck`; research.md
  decision 4), paired with a private relay on the runner and driven by `e2e mac`. Checks: files
  (find, read, change, a picture), shell (run, check), Latchkey's own browser on pages the check
  serves (read, act, a download saved), a capability turned off disappears, the Mac going
  offline answers at once (Constitution II). Everything else is listed as skipped with the
  reason (FR-1506): Notes, Calendar, Reminders, Contacts, Messages, Mail, WhatsApp, computer
  control, Passwords, location.
Deadlines are generous (no tight timing on the slower runner); a check that turns flaky is
fixed, never ignored. The checks are reported on the pull request, not required for merging
(Toni, 2026-11-25), so the `main` ruleset is unchanged; a session merges only when they passed,
or says why not (FR-1540).

### D4. Tool snapshots (FR-1504)
`relay/e2e/toolsnaps/<relay|mac|linux>/<tool>.json`: name, description, input schema, as a real
MCP client lists them through the relay with every capability on. `e2e snap` compares; with
`-update` it rewrites. The Mac's snapshots can only be listed on macOS, so `e2e-mac` uploads
the new snapshots as a workflow artifact when they differ and prints the diff; a cloud session
downloads them and commits them in the same pull request. This also makes the rule "a tool
whose behavior changes gets a new name" (`.claude/rules/tool-design.md`) visible in review.

### D5. The weekly run (FR-1510 to FR-1517)
`macos/scripts/weekly-eval.sh [--send]`, run in Terminal from any clone on an Apple silicon Mac
(it only reads the clone, and writes `e2e-results/`, which git ignores). It:
1. checks Tart and the prepared image `latchkey-eval` exist, else says to run the image script
   (D6);
2. reads the Claude token from the login keychain (research.md decision 2), builds `e2e` for
   darwin/arm64 from the clone, and keeps the Mac awake for the run (`caffeinate -i`);
3. clones the image to a run copy and starts it without a window (`tart run --no-graphics`),
   so nothing appears on the screen (FR-1514);
4. inside the copy, over SSH to the VM only: installs the newest signed Mac release (same
   signature, so the image's permissions and pairing hold), starts the stored relay, signs in
   with the stored passkey and approves a fresh client token (research.md decision 4a), and runs
   `e2e weekly` with the token in its environment only (no `ANTHROPIC_API_KEY`, never `--bare`);
5. `e2e weekly` runs every check (FR-1516), then each task 3 times from a fresh start state
   (setup, Claude Code with only Latchkey's tools, check, cleanup), starting no new task after
   one hour (FR-1515), and writes the result (`contracts/eval-result.md`);
6. copies the result into `e2e-results/<run>.json` in the clone and prints the summary; with
   `--send`, seals it to the developer's key and sends it to the intake (D7);
7. stops and deletes the copy whatever happened (a trap), and prints one line: where the result
   is, sent or not, or why it stopped.
Claude Code runs with `--mcp-config` + `--strict-mcp-config`, `--allowedTools "mcp__latchkey__*"`,
`--tools ""` (no built-in tools), `--max-turns` from the task, `--output-format stream-json
--verbose`, `--model sonnet`, an isolated `CLAUDE_CONFIG_DIR`; a run whose `system/init` shows
Latchkey not connected stops before any task (FR-1523).

### D6. The prepared image (FR-1512, FR-1513)
`macos/scripts/eval-image.sh`, once, from any clone: pulls the base image (research.md decision
4b), installs Chrome's headless shell, Claude Code and the newest Latchkey release, makes the
test certificate authority and trusts it in the test Mac, creates the relay's account and the
pairing (`e2e prepare`, inside the copy), creates the test data sets with `e2e fixture`, asks
for the Claude token at a password prompt (into the login keychain), then opens the VM's window
once for the person to click Connect and approve Latchkey's permissions (Full Disk Access,
Automation, Accessibility, Screen Recording; Screen Recording can only be approved by hand), and
shuts it down. The weekly run checks the permissions first and reports `missing_permissions`
instead of failing tasks (FR-1513). Done again only after a new macOS or a signature change.

### D7. Results and the reminder (FR-1511, FR-1530 to FR-1533)
Every run writes `e2e-results/<run>.json` in the clone (FR-1530, FR-1530a): a developer's agent
in that clone reads it directly. With `--send`, the same result is sealed and sent as
`contracts/eval-result.md` says, through the intake's existing endpoint (no intake change).
`latchkey-reports` gains `evals` (list sent results, joined by run, compared with the previous
run: new failures, fixed, flaky) and `list` keeps showing only problem reports. At session start
(CLAUDE.md, beside the problem reports, which need the same key; as a hook it would add a network
call to every session start) a session runs `latchkey-reports evals -this-week -quiet`; with none
it prints: "The weekly test run hasn't run this week: on your Mac, run
macos/scripts/weekly-eval.sh --send in Terminal from the repository (about an hour; nothing to
approve)."
The session tells Toni that line. Each new failure becomes an issue found (FR-1532); sent results
are deleted once dispositioned (FR-1533).

### D8. Tasks (FR-1520 to FR-1526)
About 20 tasks in `relay/e2e/tasks/` (format: `contracts/task-format.md`), spread over the
capabilities the test Mac has: files, shell, Latchkey's own browser on local pages (sign-in,
download), Notes, Calendar, Reminders, Contacts, computer control on a test app; 3 or 4 with
planted instructions (a note, a page, a file) (FR-1524); 4 held out (FR-1526). Regression cases
from `cases.json` that need Claude or the test Mac are written as tasks, with `covers` (FR-1525).
Scoring: end state first, then forbidden calls, unneeded calls reported; no judge.

### D9. Releases and Toni's conditions (FR-1540, FR-1541)
No release workflow changes: a merged commit is "checked" when its pull request's end-to-end
checks passed (FR-1540). `docs/STATUS.md` gets a "Weekly run" line (date, release, passes, new failures).
CLAUDE.md, "Done means Toni's conditions", gains one sentence: a weekly result is evidence only
for a condition the test Mac really has (unlocked, Latchkey's own browser, a local page, test
data), quoted with version and time; locked, lid closed, real iMessage, real sites and Toni's
accounts stay NOT VERIFIED until Toni runs them.

## Milestones (in dependency order)

1. Shared start-up in `relay/internal/e2e`, `e2e pick` with its map, `e2e snap` with the relay
   and Linux snapshots, `e2e.yml` with `e2e-linux` (D1 to D4).
2. `E2EHostTests`, `e2e mac` with its checks and the Mac snapshots, `e2e-mac` (D3, D4).
3. `e2e fixture` and the task format, tried on GitHub's macOS runner for files and the browser
   (D8).
4. `e2e prepare`, `eval-image.sh` and `weekly-eval.sh`, then the one-time image setup (D5, D6).
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
- IV (good citizen, never disturb): the test Mac runs without a window; nothing touches Toni's
  apps or data; Toni starts it himself. The image setup opens one VM window, once, when Toni
  asks for it. Pass.
- V (self-hostable): nothing in the product depends on these; GitHub and Tart are test tools.
  Pass.
- VI (store the minimum): results hold test data only; the copy and its traces are deleted.
  Pass.
- VII (test-first, real MCP client): this spec is that, end to end. Pass.
- VIII (simplicity): one new program (`relay/cmd/e2e`, D1), one workflow, two scripts, each named
  by requirements; no outside framework. Pass.
- IX (open source): no new dependency in the relay or app; Tart is a tool on Toni's Mac, not
  shipped (research.md). Pass.
- X (a tool reports; Claude judges): no tool changes; the judging is the eval's, on state, not a
  tool's. Pass.
