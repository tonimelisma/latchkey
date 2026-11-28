# Shell: design

GOVERNS: `macos/App/Shell/`

Spec 004's plan (migrated from `specs/004-shell/plan.md`, titled "Plan 004: Shell — HOW"). What it must do:
[requirements/shell.md](../requirements/shell.md). Each decision Dn is an ADR, linked
where the decision stood.

Derived from `docs/requirements/shell.md`; evidence and low-level choices in `docs/research/2026-10-22-shell.md`.

## D1. Tools (level On)

Decision record: [ADR 0047](../adr/0047-tools.md).

## D2. Running

Decision record: [ADR 0048](../adr/0048-running.md).

## D3. Jobs

Decision record: [ADR 0049](../adr/0049-jobs.md).

## D4. Output

Decision record: [ADR 0050](../adr/0050-output.md).

## D5. Levels and visibility

Decision record: [ADR 0051](../adr/0051-levels-and-visibility.md).

## D6. Leftovers are followed and swept (FR-313, FR-324, FR-326)

Decision record: [ADR 0052](../adr/0052-leftovers-are-followed-and-swept.md).

## D7. Leases (FR-314)

Decision record: [ADR 0053](../adr/0053-leases.md).

## D8. Scratch folder (FR-315, FR-316)

Decision record: [ADR 0054](../adr/0054-scratch-folder.md).

## D9. The fence (FR-317 to FR-320)

Decision record: [ADR 0055](../adr/0055-the-fence.md).

## D10. What a job left (FR-321, FR-323)

Decision record: [ADR 0056](../adr/0056-what-a-job-left.md).

## D11. Changes that got past the fence (FR-325)

Decision record: [ADR 0057](../adr/0057-changes-that-got-past-the-fence.md).

## D12. Jobs in every answer (FR-322)

Decision record: [ADR 0058](../adr/0058-jobs-in-every-answer.md).

## Testing

Real commands in tests: output and exit status, a non-zero exit, waiting then checking, input to
a `read` prompt, stopping `sleep 100`, folder, login PATH, the output limit; control-code
cleaning on fixed strings; tool list per level. A command that leaves a process in the
background ignoring Ctrl-C, hangup, and terminate: gone after stop, after stop-all, and after
Shell goes Off (with the waiting call answered); the cap with a limit of 2.

## Constitution check

| Article | Status |
|---|---|
| I. Outbound only | Pass |
| II. Fail fast | Pass: every call returns within 30 s plus margin; long work continues as a job; stopping takes at most 3 s for Ctrl-C plus 3 s to end the session |
| III. Disabled means nonexistent | Pass |
| IV. Good macOS citizen | Pass: the Owner's own permissions; no root |
| V. Self-hostable | Pass: relay unchanged |
| VI. Store the minimum | Pass: output only in memory, last 1 MB, 10 minutes after the end; Left Behind entries name files and processes, in the encrypted activity log only |
| VII. Test-first | Planned; leftovers (D6 to D12): tests first, with real commands and a real sandbox, stand-ins only for the Trash and the record |
| VIII. Simplicity | Pass: system `script`, `sandbox-exec`, and zsh; no new dependency |
| IX. Open source | Pass |

## D13. Self-check at start (FR-330, 2026-10-29)

Decision record: [ADR 0059](../adr/0059-self-check-at-start.md).
