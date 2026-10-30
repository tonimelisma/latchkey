# Spec 004: Shell — WHAT and WHY

Status: Built without a review stop (Toni, 2026-10-22); reviewed and approved by Toni, 2026-10-29.
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
- **FR-310** When the Owner turns Shell off, the Mac shall at once stop every running command,
  including those that kept running after their answer was given, and answer a command Claude
  is waiting on with an error saying the Mac's owner turned Shell off (spec 001 FR-066; Toni,
  2026-10-25).
- **FR-311** When a command is stopped (by Claude, by turning Shell off, or by quitting
  Latchkey), everything it started that is still running in its terminal shall be stopped with
  it (security review, 2026-10-25).
- **FR-312** The Mac shall run at most 32 commands at once; a further one shall be refused with
  an error telling Claude to wait for one to finish or to stop one (security review,
  2026-10-25).

### Nothing left behind (Toni, 2026-10-27)

Why: on 2026-10-25 a command left two headless Chrome processes running for two days, and
commands left a 118 MB download, Chrome profiles, and logs in `/tmp`, beside results Toni
wanted (receipts in Downloads, a key file). The answer: a command's leftovers are stopped and
removed unless Claude asked to keep them for a time; writes go only where they are meant to; and
what is left is on one list.

- **FR-313** When a command finishes, every process it started that is still running shall be
  stopped, whether it stayed in the command's terminal or left it (a new session, `nohup`),
  unless Claude asked to keep the command's leftovers (FR-314).
- **FR-314** When starting a command, Claude shall be able to ask to keep what it leaves running
  and its scratch folder for a number of minutes after it finishes (its lease). Checking the job
  shall start that time again. A lease shall never reach past 24 hours after the command
  finished. When the lease ends, the leftovers shall be stopped and removed as in FR-313 and
  FR-316.
- **FR-315** Each command shall have its own scratch folder, used by programs for their
  temporary files, and Claude shall be told where it is.
- **FR-316** When a command's leftovers are removed, its scratch folder shall be moved to the
  Trash (an empty one is deleted).
- **FR-317** A command, and everything it starts, shall be able to write only to its scratch
  folder, the folder Claude ran it in (unless that is the home folder or a folder above it),
  Downloads, the caches package tools use, and what Claude declared when starting it (FR-318).
  Any other write shall fail.
- **FR-318** When starting a command, Claude shall be able to declare the folders or files it
  will write and why. Declaring the home folder, a folder above it, or the whole Library folder
  shall be refused with an error asking for the specific folder.
- **FR-319** Shell startup files, launch agents, login items, `~/.ssh`, and git hooks shall be
  writable only when declared (`~/.ssh` and git hooks added by Toni, 2026-10-28), even inside an allowed folder; Latchkey's own files never.
- **FR-320** When a command's output shows a write refused under FR-317, the answer shall tell
  Claude how to write there: use the scratch folder, or declare the folder and run it again.
- **FR-321** When a command finishes, its answer shall say what it left: the processes stopped,
  the scratch folder removed or kept until when, and the new files in what it declared and in
  Downloads.
- **FR-322** While any command is running or its leftovers are kept, every tool answer shall end
  with a line naming those commands and when each lease ends.
- **FR-323** What a command left shall be recorded in the activity log as Left Behind entries
  (spec 001 FR-640): processes stopped, scratch removed, results kept, and declared permanent
  changes (FR-319) marked as such.
- **FR-324** When Latchkey starts, it shall stop the processes and remove the scratch folders
  that an earlier run of Latchkey left (after a crash), and record them.
- **FR-325** When a launch agent, a login item, or a shell startup file changes while a command
  runs or its leftovers are kept, and no command declared it, Latchkey shall record it and notify
  the Owner. A process of a command that can't be stopped shall be recorded and notified too.
  Nothing else Shell leaves is notified.
- **FR-326** When Latchkey quits or Shell is turned off, kept leftovers shall be stopped and
  removed as well (FR-309, FR-310).
- **FR-327** A program a command started shall be stopped with the command's leftovers however
  it left the command's terminal session and family (a quick double fork included), and shall
  be found at the next start when Latchkey quit first.
- **FR-328** When a command opens apps, files, or links through macOS (`open`), it shall be
  refused unless Claude declared it (`uses`: `open`), and the answer shall say how to declare it.
  When a command tells other apps what to do (AppleScript, `osascript`), it shall always be
  refused, and the answer shall point to Latchkey's own tools (Toni, 2026-10-29: a script must
  run outside the fence to reach an app and could then run anything; `app_scripts` withdrawn). Starting
  background services through launchd (`launchctl`, `brew services`) shall be refused (Toni,
  2026-10-28).
- **FR-329** When a command changes settings through macOS's settings service (`defaults
  write`), it shall be refused unless Claude declared that domain's file in
  `~/Library/Preferences` in writes, and Latchkey's own settings never; reading settings shall
  keep working, and the answer shall say how to declare it (Toni, 2026-10-28).
- **FR-330** When Latchkey starts, it shall check that the fence refuses a write and that a
  program inside a fence is found by its mark (FR-327). When either fails, commands shall still
  run, every Shell answer shall say that writes may not be fenced and leftovers may not all be
  stopped, and the Owner shall be notified once (Toni, 2026-10-29).
- A scratch shell in a throwaway Linux container was considered and left out (Toni,
  2026-10-27).

## Success criteria

- **SC-301** From the phone, "how much disk space is free?" is answered from `df`.
- **SC-302** A 2-minute command started from the phone finishes and its result is reported.
- **SC-303** With Shell Off, no shell tool appears (test suite).
- **SC-304** A command that starts headless Chrome in the background and writes to `/tmp`
  leaves nothing running and nothing in `/tmp` once it finishes; a file it saves to Downloads
  stays and is listed (test suite and live check).

## Edge cases

- Commands waiting for a password (`sudo`): Claude is told the command is waiting for input it
  can't give; it can stop it.
- Huge output; output with progress bars; commands that never end; many jobs at once.
- The Mac going to sleep or Latchkey quitting mid-command.
- A command that detaches something from its terminal (a new session, `nohup`): still known as
  the command's, stopped with its leftovers (FR-313), also when it leaves through a parent that
  exits at once (a quick double fork, FR-327). Something opened through macOS (`open -a`) or
  told what to do by a script is started by macOS, not by the command: refused unless declared
  (FR-328); once declared, what it starts runs outside the fence and keeps running (it could
  start Terminal with a command, for example). launchd refuses jobs from inside the fence.
- Settings changed through `defaults` are refused unless declared (FR-329). Other programs a
  command asks over their own channels (a database server, a running app's own socket) are
  outside the fence; only FR-325's places are watched.
