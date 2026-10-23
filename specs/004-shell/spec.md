# Spec 004: Shell — WHAT and WHY

Status: Approved to build without a review stop (Toni, 2026-10-22); Toni reviews at the end.
Scope: Claude runs commands on the Mac as the Owner, including long and interactive ones.
Out of scope: administrator (root) commands.

## Problem

Anything without a dedicated tool (scripts, git, Homebrew, checking disk space, converting a
video) needs a terminal. From a phone, there is none.

## User stories

### US1 (P1): Run a command from anywhere
1. Given Shell is On, when I ask "how much disk space is left?", then Claude runs a command and
   answers from its output.
2. Given a command takes ten minutes, then Claude starts it, checks on it later, and tells me
   when it's done.
3. Given a command asks "Continue? [y/n]", then Claude can answer it.
4. Given a command is stuck, then Claude can stop it.

## Requirements

- **FR-301** While Shell is On, Claude shall be able to run a command in the Owner's login
  shell, as the Owner, in a chosen folder, and get its output and exit status.
- **FR-302** When a command runs longer than the wait Claude asked for (at most 30 seconds),
  the answer shall give the output so far and a job id, and the command shall keep running.
- **FR-303** Claude shall be able to check a job's new output and status, type input into it,
  stop it, and list jobs.
- **FR-304** Commands shall run in a terminal, so programs that ask questions behave as in
  Terminal; terminal control codes shall be removed from what Claude sees.
- **FR-305** Output shall stay within Claude's result size, keeping the most recent part and
  saying so.
- **FR-306** Commands shall never run as administrator; Latchkey's keep-awake helper is not used.
- **FR-307** Each command Claude runs shall show a notification and appear in the menu's
  activity.
- **FR-308** Shell shall have the levels Off and On, and start On (Toni, 2026-10-22).
- **FR-309** When Latchkey quits, its running commands shall be stopped.

## Success criteria

- **SC-301** From the phone, "how much disk space is free?" is answered from `df`.
- **SC-302** A 2-minute command started from the phone finishes and its result is reported.
- **SC-303** With Shell Off, no shell tool appears (test suite).

## Edge cases

- Commands waiting for a password (`sudo`): Claude is told the command is waiting for input it
  can't give; it can stop it.
- Huge output; output with progress bars; commands that never end; many jobs at once.
- The Mac going to sleep or Latchkey quitting mid-command.
