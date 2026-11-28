# 0052. Leftovers are followed and swept (FR-313, FR-324, FR-326)

- Status: accepted
- Date: 2026-10-27
- Alias: plan 004 D6 (`specs/004-shell/plan.md`, "D6. Leftovers are followed and swept (FR-313, FR-324, FR-326)")

## Context and problem

Decision D6 of spec 004's plan (Shell); requirements in
[requirements/shell.md](../requirements/shell.md). Requirement IDs it cites: FR-313, FR-324, FR-326, FR-325, FR-327.
The design it belongs to: [design/shell.md](../design/shell.md).

## Decision


A job's processes are found three ways, all with public process information (`libproc`):
- its terminal session (D3), which keeps an ordinary background process (`&`, `nohup`) even
  after the shell that started it has exited;
- its family: every half second while any job runs, and again when one ends, each process whose
  parent is one of the job's is added to the job, until nothing new turns up; a process is known
  by its id and start time, so an id the system gives to another process later is never
  mistaken for it. This keeps a process that left the session (`setsid`) as the job's;
- at the sweep, any process started since the job began whose working folder or an open file is
  in the job's scratch folder, such as a browser with its profile there.
Sweeping a job: terminate all of these, then kill after 1 s; one still there after that is
reported (FR-325). The sweep runs when the command ends and its lease is zero, when its lease
ends (D7), when the job is stopped, on quit and Shell Off, and at start for what jobs of an
earlier run left (each job keeps its known processes in `<scratch folder>.pids` beside the
scratch folder).
- its mark (FR-327, 2026-10-28): each job's fence refuses reading one empty file,
  `<scratch folder>.mark` beside the scratch folder, and a sandbox is inherited by everything
  started inside it and can't be left. A process whose sandbox refuses reading the mark but
  not a second empty file beside it (`<scratch folder>.open`) is the job's, wherever it went: a
  quick double fork included. Another sandbox that keeps a process out of Latchkey's folder, or
  away from files, refuses both and is left alone. (0.8.38 to 0.8.40 compared the mark with the
  scratch folder; macOS's font service, whose sandbox refuses every file but no folder, was
  stopped after every command and restarted by launchd; live check 2026-10-29.)
  At start, the marks of an earlier run find what its records missed. The check is macOS's
  `sandbox_check`, called through a small C file (research.md).
Opening through LaunchServices and scripting other apps are refused unless declared (D9), so
nothing a command starts runs outside its sandbox unless Claude asked.

An inherited environment variable was the first plan: macOS 27 no longer shows another
process's environment (`KERN_PROCARGS2` returns the arguments only, also to `ps -E`), so it
can't be read back (research.md).

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/LeftoversTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
