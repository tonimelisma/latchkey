# 0167. The per-pull-request workflow (FR-1501 to FR-1506)

- Status: accepted
- Date: 2026-11-24
- Alias: plan 015 D3 (`specs/015-e2e-evals/plan.md`, "D3. The per-pull-request workflow (FR-1501 to FR-1506)")

## Context and problem

Decision D3 of spec 015's plan (End-to-end tests and evals); requirements in
[requirements/e2e-evals.md](../requirements/e2e-evals.md). Requirement IDs it cites: FR-1501, FR-1506, FR-1503, FR-1540.
The design it belongs to: [design/e2e-evals.md](../design/e2e-evals.md).

## Decision

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
(decided 2026-11-25), so the `main` ruleset is unchanged; a session merges only when they passed,
or says why not (FR-1540).

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/E2EHostTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
