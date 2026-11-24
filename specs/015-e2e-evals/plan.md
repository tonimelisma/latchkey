# Spec 015 plan: end-to-end tests and evals — HOW

Status: Draft for Toni's review (2026-11-24). Requirements: `spec.md`. Findings and the
low-level choices Claude made: `research.md`. Formats: `contracts/task-format.md`,
`contracts/eval-result.md`.

## Shape

```
Per pull request (GitHub, blocks merging)          Weekly (Toni starts it on his Mac)
  e2e.yml                                            macos/scripts/weekly-eval.sh
   ├─ pick: changed paths → capabilities              ├─ tart clone latchkey-eval → run copy
   ├─ e2e-linux (ubuntu): relay + Linux program        ├─ inside the copy:
   │    real MCP client, toolsnaps relay/linux         │    newest signed release, private relay,
   └─ e2e-mac (macos-26): Debug Mac app + relay        │    checks (all), ~20 tasks × 3 with
        real MCP client, local pages, toolsnaps mac    │    Claude Code (Sonnet, ≤ 1 hour)
                                                       │    → sealed results → developer intake
                                                       └─ tart delete the copy
Cloud session start: no result this week? → one line to Toni: what to run.
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
- `e2e-mac` (macos-26): the Mac app built for Debug, signed ad hoc, started with the Debug-only
  pairing setting (research.md decision 4), paired with a private relay on the runner. Checks:
  files (find, read, change, a picture), shell (run, check, the fence), Latchkey's own browser on
  pages the check serves (read, act, a local sign-in form typed with a test login, a download
  saved), a capability turned off disappears, the Mac going offline answers at once
  (Constitution II). Everything else is listed as skipped with the reason (FR-1506): Notes,
  Calendar, Reminders, Contacts, Messages, Mail, WhatsApp, computer control, Passwords.
Deadlines are generous (no tight timing on the slower runner), since every check blocks (Toni,
"All block"); a check that turns flaky is fixed, never made optional. Adding `e2e-linux` and
`e2e-mac` to the `main` ruleset's required checks is a settings change a cloud session can't
make (GitHub refuses it through the proxy): one of Toni's steps, below.

### D4. Tool snapshots (FR-1504)
`relay/e2e/toolsnaps/<relay|mac|linux>/<tool>.json`: name, description, input schema, as a real
MCP client lists them through the relay with every capability on. `e2e snap` compares; with
`-update` it rewrites. The Mac's snapshots can only be listed on macOS, so `e2e-mac` uploads
the new snapshots as a workflow artifact when they differ and prints the diff; a cloud session
downloads them and commits them in the same pull request. This also makes the rule "a tool
whose behavior changes gets a new name" (`.claude/rules/tool-design.md`) visible in review.

### D5. The weekly run (FR-1510 to FR-1517)
`macos/scripts/weekly-eval.sh`, run by Toni in Terminal from the main checkout (it only reads
it). It:
1. checks Tart and the prepared image `latchkey-eval` exist, else says what to do (D6);
2. reads the Claude token from Toni's login keychain (research.md decision 2) and keeps his Mac
   awake for the run (`caffeinate -i`);
3. clones the image to a run copy and starts it without a window (`tart run --no-graphics`), so
   nothing appears on Toni's screen (FR-1514);
4. inside the copy, over SSH to the VM only: installs the newest signed Mac release (same
   signature, so the image's permissions hold), starts a private relay, pairs, and runs
   `e2e weekly` with the token in its environment only (no `ANTHROPIC_API_KEY`, never `--bare`);
5. `e2e weekly` runs every check (FR-1516), then each task 3 times from a fresh start state
   (setup, Claude Code with only Latchkey's tools, check, cleanup), stopping new tasks at one
   hour (FR-1515); it seals the results to the developer's key and sends them to the intake
   (D7);
6. stops and deletes the copy whatever happened (a trap), and prints one line: sent, or why not.
Claude Code runs with `--mcp-config` + `--strict-mcp-config`, `--allowedTools "mcp__latchkey__*"`,
no built-in tools, `--max-turns` from the task, `--output-format stream-json --verbose`, an
isolated `CLAUDE_CONFIG_DIR`; a run whose `system/init` shows Latchkey not connected stops
before any task (FR-1523).

### D6. The prepared image (FR-1512, FR-1513)
`macos/scripts/eval-image.sh` (Toni, once): pulls a macOS base image with Tart, installs Claude
Code, Go's `e2e` binary and the newest Latchkey release in it, creates the test data sets with
`e2e fixture` (Notes, Calendar, Reminders, Contacts, files, a test keychain of fake logins for
the local pages; every item tagged), then opens the VM's window once so Toni approves
Latchkey's permissions (Full Disk Access, Automation, Accessibility, Screen Recording; Screen
Recording can only be approved by hand), and shuts it down. The weekly run checks the
permissions first and reports `missing_permissions` instead of failing tasks (FR-1513). Done
again only after a new macOS or a signature change.

### D7. Results and the reminder (FR-1511, FR-1530 to FR-1533)
Results are sealed and sent as `contracts/eval-result.md` says, through the intake's existing
endpoint (no intake change). `latchkey-reports` gains `evals` (list weekly results, joined by
run, compared with the previous run: new failures, fixed, flaky) and `list` keeps showing only
problem reports. The session-start hook (`scripts/hooks.sh`, cloud sessions only, where the
developer's key is) runs `latchkey-reports evals --this-week`; with none it prints: "The weekly
test run hasn't run this week: on your Mac, run macos/scripts/weekly-eval.sh in Terminal (about
an hour; nothing to approve)." The session tells Toni that line. Each new failure becomes an
issue found (FR-1532); results are deleted once dispositioned (FR-1533).

### D8. Tasks (FR-1520 to FR-1526)
About 20 tasks in `relay/e2e/tasks/` (format: `contracts/task-format.md`), spread over the
capabilities the test Mac has: files, shell, Latchkey's own browser on local pages (sign-in,
download), Notes, Calendar, Reminders, Contacts, computer control on a test app; 3 or 4 with
planted instructions (a note, a page, a file) (FR-1524); 4 held out (FR-1526). Regression cases
from `cases.json` that need Claude or the test Mac are written as tasks, with `covers` (FR-1525).
Scoring: end state first, then forbidden calls, unneeded calls reported; no judge.

### D9. Releases and Toni's conditions (FR-1540, FR-1541)
No release workflow changes: required checks already make a merged commit "checked"
(FR-1540). `docs/STATUS.md` gets a "Weekly run" line (date, release, passes, new failures).
CLAUDE.md, "Done means Toni's conditions", gains one sentence: a weekly result is evidence only
for a condition the test Mac really has (unlocked, Latchkey's own browser, a local page, test
data), quoted with version and time; locked, lid closed, real iMessage, real sites and Toni's
accounts stay NOT VERIFIED until Toni runs them.

## Milestones (in dependency order)

1. Shared start-up in `relay/internal/e2e`, `e2e pick` with its map, `e2e snap` with the relay
   and Linux snapshots, `e2e.yml` with `e2e-linux` (D1 to D4).
2. The Debug pairing setting (security review), `e2e-mac` with its checks and the Mac snapshots
   (D3, D4).
3. `e2e fixture` and the task format, tried on GitHub's macOS runner for files and the browser
   (D8).
4. `eval-image.sh` and `weekly-eval.sh`, then Toni's one-time image setup (D5, D6).
5. Sealed results, `latchkey-reports evals`, the session-start line (D7).
6. The task set, held-out and planted-instruction tasks (D8); docs (D9).

## Toni's steps (all together, once)

1. Make the subscription token: `claude setup-token` on his Mac, saved in his login keychain by
   `eval-image.sh` when it asks (one paste into a password prompt, never into a chat).
2. Run `macos/scripts/eval-image.sh` and approve Latchkey's permissions in the test Mac's
   window when it opens (one sitting, about 10 minutes).
3. Approve adding `e2e-linux` and `e2e-mac` to the required checks of `main` (one command run
   through Latchkey on his Mac, the way the ruleset was set on 2026-11-24).
Then each week, only if the session says it hasn't run: `macos/scripts/weekly-eval.sh`.

## Consistency check (CLAUDE.md step 3a)

- Every requirement has a mechanism: FR-1500 D2; FR-1501 D1, D3; FR-1502 D3; FR-1503 D3;
  FR-1504 D4; FR-1505 D3; FR-1506 D3; FR-1510 D5; FR-1511 D7; FR-1512 D5, D6; FR-1513 D6;
  FR-1514 D5; FR-1515 D5; FR-1516 D5; FR-1517 D5 (never called by a workflow); FR-1520 to
  FR-1526 D8 and the task contract; FR-1530 to FR-1533 D7 and the result contract; FR-1540,
  FR-1541 D9.
- No new message crosses the relay–Mac boundary: the checks use the existing MCP surface and
  agent protocol. The only new pairing path is Debug-only (research.md decision 4).
- The intake (spec 014) is unchanged: results use its existing endpoint and 64 KB limit.
- Spec 001 FR-680 to FR-689 (traces) are unchanged: the copy's traces go with the copy.
- The regression-tests work (`docs/regression-coverage.md`) adds unit and CI tests; this spec
  adds end-to-end checks and Claude tasks, and FR-1525 links tasks to the same case ids. No
  overlap in files.

## Constitution check

- I (outbound only): the Mac app dials out to a relay on the same runner or inside the copy;
  nothing listens on Toni's Mac. Pass.
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
