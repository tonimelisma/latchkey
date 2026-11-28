# 0169. The weekly run (FR-1510 to FR-1517)

- Status: accepted
- Date: 2026-11-24
- Alias: plan 015 D5 (`specs/015-e2e-evals/plan.md`, "D5. The weekly run (FR-1510 to FR-1517)")

## Context and problem

Decision D5 of spec 015's plan (End-to-end tests and evals); requirements in
[requirements/e2e-evals.md](../requirements/e2e-evals.md). Requirement IDs it cites: FR-1510, FR-1517, FR-1514, FR-1516, FR-1515, FR-1523.
The design it belongs to: [design/e2e-evals.md](../design/e2e-evals.md).

## Decision

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
   one hour (FR-1515), and writes the result (`docs/design/contracts/eval-result.md`);
6. copies the result into `e2e-results/<run>.json` in the clone and prints the summary; with
   `--send`, seals it to the developer's key and sends it to the intake (D7);
7. stops and deletes the copy whatever happened (a trap), and prints one line: where the result
   is, sent or not, or why it stopped.
Claude Code runs with `--mcp-config` + `--strict-mcp-config`, `--allowedTools "mcp__latchkey__*"`,
`--tools ""` (no built-in tools), `--max-turns` from the task, `--output-format stream-json
--verbose`, `--model sonnet`, an isolated `CLAUDE_CONFIG_DIR`; a run whose `system/init` shows
Latchkey not connected stops before any task (FR-1523).

## Confirmation

The tests that validate the requirements it cites:

- `relay/internal/evals/evals_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
