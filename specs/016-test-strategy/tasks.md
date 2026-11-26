# Spec 016: Tasks

Approved by Toni 2026-11-26 ("do everything we've aligned on"). `[P]` = can run in parallel.
Each task names its requirements; done means its check passed where it says.

## Pull request 1 (cloud): the gate and the docs

- [x] T1 Two ways to work in CLAUDE.md, cloud-sessions.md, the start hook (D6).
- [x] T2 CLAUDE.md trim and Toni's four rule changes; `loose-ends.sh` 3-day rule with its test.
- [x] T3 FR-1607: a development build never offers to move or replaces the installed app;
      `InstallationTests` regression test. Check: GitHub Mac run, unit tests 0 failed.
- [x] T4 FR-1601: Mac tests gate merging. `mac-build.yml` runs on every pull request; job `mac`
      passes when `macos/` didn't change, else only when all four build-and-test jobs passed;
      `continue-on-error` off. Check: pull request #59's run (all green, gate passed); a pull
      request without `macos/` changes: pull request #60's first commit (6c46064), `mac` passed
      15 s after the push with no Mac job started.
- [x] T5 `ci.yml` on pull requests and main only (no double run).
- [x] T6 After merge: the ruleset `main` requires `mac` (Toni allowed, 2026-11-26, this once:
      through Latchkey's shell on his Mac with `gh`). Check: the ruleset read back. Done
      2026-11-26 07:4x UTC: ruleset `main` requires relay, linux, scripts, mac (read back).
- [x] T7 FR-1612: measure every workflow's time from push to last check on this pull request
      and main; record in `research.md` §5; report each layer over 5 minutes with its reason.
      Done: a non-Mac change ~3 min; a Mac change ~5 m 25 s without waiting for a machine
      (research §5, with what is left over 5 minutes and why).

## Pull request 2 (cloud; the sandbox's first run needs a local session)

- [x] T8 [P] FR-1603: one harness. Remove `cmd/localcheck`, `cmd/maccheck` + `LiveRelayTests`,
      `cmd/guidecheck`, `make claude-check`, `make mac-check`; their checks move to the sandbox
      (T11) and an eval task (the relay-setup guide). Docs and script tests follow.
- [x] T9 [P] FR-1609, D5: retire `macos/scripts/state-check/` and `safari-check*`; map their
      cases in `docs/regression-coverage.md` (sandbox check, eval task, or Toni's checklist in
      `docs/screen-states.md`); CLAUDE.md, commands, development docs follow.
- [x] T10 [P] FR-1604: one place per behavior. Tool names, descriptions and schemas only in
      `relay/e2e/toolsnaps`: trim `PublicToolsTests` to what snapshots don't show; replace tests
      that pin description sentences by their snapshot.
- [x] T11 FR-1605, FR-1606, FR-1610, D3: `make sandbox` (`macos/scripts/sandbox.sh`): build
      Release signed with the sandbox's own self-signed identity, start or reuse a Tart copy of
      `latchkey-eval`, install the build, seed test data, run `cmd/e2e sandbox` (every
      capability, the moved `maccheck` checks), results in `e2e-results/`. `make sandbox-stop`.
      Check: script tests in CI (argument refusals, nothing personal read): `sandbox_test.sh`
      49/49; a real run NOT VERIFIED until a local session runs it.
- [x] T12 FR-1608, D4: `make evals` on the sandbox (local build or `--release`), was
      `weekly-eval.sh`.
- [x] T13 [P] FR-1602: deadline tests on fake clocks (Swift `Clock` injected; Go
      `testing/synctest`); `timing-suites.txt` and `quiet-suites.txt` shrink as suites move.
      Done for `Deadline.first` and `CodeFinder` (Swift `ManualClock`), `DeadlineTests` out of
      both lists; the relay's alert-slot tests in synctest (1.6 s to 0.3 s). Left, each needing a
      clock threaded through app code: CloudFile, LevelChange, SingleCopy, PasswordsExportCleanup,
      ActivityLogScale; real processes stay on real time (FencedBuild, ShellJob, Leftovers).
- [x] T14 The start hook tells a local session to run `make sandbox` after building the Mac app.
- [x] T15 FR-1612 again on pull request 2; STATUS, decisions, README where they change.
- [ ] T16 (local session) First `make -C macos sandbox` on a Mac with Tart: `eval-image.sh` once
      (Toni approves the image's permissions once), then the run; fix what it finds. Then port
      the rest of `relay/e2e/sandbox-checks.md` into `e2e sandbox` (Safari tabs, the fuller
      per-app groups, maps, front app unchanged, no permission prompts), each seen working there.
