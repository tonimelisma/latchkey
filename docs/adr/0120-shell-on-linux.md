# 0120. Shell on Linux (FR-1030 to FR-1034)

- Status: accepted
- Date: 2026-11-01
- Alias: plan 010 D9 (`specs/010-multi-host/plan.md`, "D9. Shell on Linux (FR-1030 to FR-1034)")

## Context and problem

Decision D9 of spec 010's plan (Several machines and Linux servers); requirements in
[requirements/multi-host.md](../requirements/multi-host.md). Requirement IDs it cites: FR-1030, FR-1034, FR-1031, FR-1032, FR-324, FR-330, FR-1033.
The design it belongs to: [design/multi-host.md](../design/multi-host.md).

## Decision


Same two tools and arguments as the Mac minus `writes`, `why`, `uses`. Bash as a login shell
(`/bin/bash -l -c`, the command passed in the environment and run with `eval`, so `/etc/profile`
can't drop the sudo wrapper from `PATH`), in a terminal (pty), 32 at once, `wait` up to 30 s then
a job id, input/stop/check, output tail kept within 20,000 characters, terminal codes stripped. A
job ends when its command's process exits, not when the terminal closes: a leftover holding the
terminal would keep it open for ever (found in the Linux container tests, 2026-11-01).

- **Shell's own switch** (FR-1034): Shell off or pause first refuses new commands, under the lock
  a starting command takes, then stops the running ones; a command already starting when the
  switch flips is stopped once registered.
- **sudo** (FR-1031): every command's `PATH` starts with a folder holding a `sudo` wrapper that
  runs the real sudo with `-n` (never asks). When sudo answers "a password is required", the
  answer adds: "sudo needs a password on this server, and Latchkey never types one. The server's
  owner can allow passwordless sudo (NOPASSWD in /etc/sudoers.d) for the commands Claude should
  run." A prompt reaching the terminal anyway (a full path to sudo) is noticed in the output
  ("[sudo] password for") and the job is stopped with the same text.
- **Leftovers** (FR-1032): the service lives in its own delegated control group (cgroup v2).
  At start it moves itself into `<own>/service` and makes `<own>/jobs/<id>` per command; the
  command and everything it starts, sudo included, stay in that group (verified on Debian 12;
  distributions whose sudo uses pam_systemd unverified, research.md). When a command ends
  without a lease, the job's group is killed (`cgroup.kill`, which the kernel applies to every
  process in it whatever its user) and its scratch folder deleted; with `keep_minutes`, at the
  lease's end (checking renews it, 24 h at most). Groups and scratch folders from an earlier run
  are removed at start (FR-324's rule). Without cgroup v2 delegation (an old system, or running
  outside the service), commands still run and every Shell answer says leftovers may not be
  stopped (FR-330's rule).
- **Scratch**: `$XDG_RUNTIME_DIR`-independent `~/.cache/latchkey/jobs/<id>`, given as `TMPDIR`
  and `LATCHKEY_SCRATCH`; deleted (FR-1033).

## Confirmation

The tests that validate the requirements it cites:

- `linux/internal/shell/shell_linux_test.go`
- `linux/internal/shell/shell_test.go`
- `macos/Tests/LeftoversTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
