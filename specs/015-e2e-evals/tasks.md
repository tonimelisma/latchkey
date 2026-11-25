# Spec 015 tasks

Approved by Toni 2026-11-24 ("build it fully"). Status per task at the end. Each task names the requirements it serves.
`[P]` = can be done in parallel with the task before it. Tests first where a test can run in a
cloud session (Go); Swift and the test Mac are checked on GitHub's macOS runner and, for the
weekly run, by the person running it.

## Milestone 1: picking, snapshots, Linux checks
- T01 `relay/internal/evals`: the path map (`relay/e2e/capabilities.json`), `Select`, and a
  test that every source file under `macos/App/`, `linux/`, `relay/internal/` matches a glob
  (FR-1500). Test first.
- T02 [P] Tool snapshots: `evals.Snapshot`, compare, `-update`, a readable diff (FR-1504). Test
  first.
- T03 `relay/cmd/e2e pick` (prints the selection for a base ref, GitHub output format) and
  `e2e relay` (private relay, a pretend Mac with no tools: the relay's own tools snapshotted,
  `machines`, the offline answer, a capability turned off disappears) (FR-1501, FR-1503).
- T04 `linuxcheck -toolsnaps <dir>`: the Linux program's tools compared with their snapshots
  (FR-1504).
- T05 `.github/workflows/e2e.yml`: `pick`, `e2e-linux` always running, passing at once when
  nothing is selected (FR-1502, FR-1503).

## Milestone 2: the Mac on GitHub's runner
- T06 `macos/Tests/E2EHostTests.swift`: the app's real capabilities served through the real
  connection, driven by a control file (research.md decision 4).
- T07 `e2e mac`: starts the host test, pairs, and checks files, shell, Latchkey's own browser
  on served pages and a download, a capability turned off, the offline answer; the rest listed
  as skipped (FR-1501, FR-1505, FR-1506); the Mac snapshots, uploaded when they differ (FR-1504).
- T08 `e2e-mac` job in `e2e.yml` (FR-1502).

## Milestone 3: tasks and scoring
- T09 Task format and loader (`contracts/task-format.md`), with checks of each task file
  (FR-1520). Test first.
- T10 [P] Claude Code runner: stream-json parsing (tool calls, errors, turns, tokens, MCP
  status), FR-1523 stop; scoring (FR-1521, FR-1522); pass^3. Test first with recorded streams.
- T11 `e2e fixture`: setup, check and cleanup commands for files, Notes, Calendar, Reminders,
  Contacts, served pages, on macOS (AppleScript and the file system).
- T12 The task set: about 20 tasks, 4 held out, 3 or 4 with planted instructions, `covers`
  linked to `cases.json` (FR-1524 to FR-1526).

## Milestone 4: the test Mac
- T13 `e2e prepare` (inside the copy, once): the relay's account, pairing link, the stored
  passkey; `e2e weekly` (inside each copy): sign-in with the stored passkey, checks, tasks,
  the one-hour cap, the result file (FR-1512 to FR-1516).
- T14 `macos/scripts/eval-image.sh` and `macos/scripts/weekly-eval.sh [--send]` (FR-1510,
  FR-1512 to FR-1514); `e2e-results/` ignored by git.
- T15 Script tests for both scripts' argument handling and their refusal without Tart or the
  image (`scripts/tests/`).

## Milestone 5: results
- T16 `e2e send` / `--send`: seal, split under 64 KB, prove, post (FR-1530); `reports.SealRaw`
  and `OpenRaw`. Test first.
- T17 `latchkey-reports evals` (its `-this-week` reminder removed 2026-11-25, FR-1511 withdrawn): sent results by run, compared with the
  previous one; `list` shows problem reports only (FR-1531). Test first.
- T18 The session-start step (CLAUDE.md) that tells Toni when no result was sent this week (FR-1511).

## Milestone 6: docs and release
- T19 `docs/commands.md`, `docs/cloud-sessions.md`, CLAUDE.md "Done means Toni's conditions"
  (FR-1541), STATUS, decisions, README (testing paragraph).
- T20 CI green on the pull request (the checks stay reported, not required: Toni, 2026-11-25).

## Status (2026-11-24)

Built: T01 to T19. Checked here (cloud session): Go unit tests (`internal/evals`, `cmd/e2e`,
`cmd/latchkey-reports`, `reports`), `e2e relay` end to end against a private relay with headless
Chrome, the scripts' test. Checked on GitHub: `e2e-linux` (the relay and Linux checks, Linux
snapshots taken from its artifact), `e2e-mac` (all four checks passed on macos-26 once the
browser tool's new name and the page and job names were read right; Mac snapshots taken from
its artifact). Not run anywhere yet: the
weekly run and the image script (they need an Apple silicon Mac with Tart; only a person at that
Mac can approve the test Mac's permissions). T20: done; the checks stay reported, not required (Toni, 2026-11-25).
