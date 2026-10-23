# Research 004: Shell

Done 2026-10-22 with 003, 005, 006.

## Existing servers

- Desktop Commander: `start_process` (returns after initial output, keeps running),
  `interact_with_process` (send input), `read_process_output` (paged), `force_terminate`,
  `list_sessions`, `list_processes`, `kill_process`; a configurable blocked-command list that it
  says is not a sandbox (substitution, absolute paths, and scripts get around it).
  https://github.com/wonderwhy-er/DesktopCommanderMCP
- Consequence for Latchkey: a block list would only look like safety. Toni decided on no
  Latchkey-side approvals (2026-10-22); Claude's apps ask before tool calls.

## macOS

- Commands run as the logged-in user, with that user's permissions and Full Disk Access
  inherited from Latchkey (the responsible process). `sudo` needs a password and a terminal;
  it fails. Latchkey's root helper is never used for commands (Constitution IV).
- A login shell (`/bin/zsh -l`) loads the user's PATH (Homebrew, etc.).
- Programs that ask questions ("y/n", passwords, Python's prompt) need a terminal; a
  pseudo-terminal (`openpty`) makes them behave as in Terminal. Output then carries terminal
  control codes, which are removed before Claude sees them.
- Works while the screen is locked.

## Choices (low-level, Claude's)

- **Run**: waits up to 30 s (or the requested shorter time) for the command to finish; if it
  is still running, the answer has the output so far and a job id, and the command keeps
  running (start + check pattern, decided 2026-10-22).
- **Check**: new output since the last check, waiting up to 30 s for more or for the end.
- **Output**: control codes and carriage-return redraws removed; the last 1 MB per job kept in
  memory; at most 50,000 characters per answer (the most recent part, saying so).
- **Environment**: `TERM=dumb`, `NO_COLOR=1`, `PAGER=cat`, `GIT_PAGER=cat` so tools don't page
  or color; working folder the home folder unless given.
- **Stop**: interrupt (like Ctrl-C), then kill after 3 s. All jobs are stopped when Latchkey quits.
- **Finished jobs** are kept for 10 minutes so their output can still be read, at most 20.
- **Visibility**: each command Claude runs posts a notification ("Claude ran: …") and appears
  in the menu's activity, like other changes (spec 002 FR-130).
