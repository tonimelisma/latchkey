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

## Nothing left behind (2026-10-27)

What happened, and how other agent tools handle it: `docs/ideas/leftovers.md` (history) and the
discussion with Toni of 2026-10-27. Other tools prevent rather than clean up: Claude Code, Codex,
and Gemini CLI fence a command's writes with macOS's sandbox (Seatbelt, `sandbox-exec`) to the
work folder and the temporary folder; ChatGPT agent, Anthropic's computer-use reference, Docker
Sandboxes, and Cua run in a throwaway machine. Nobody keeps a list of what was left.

Checked on this Mac (macOS 27.0.1): `sandbox-exec` with a write fence works under `script`;
later rules win over earlier ones (a refusal inside an allowed folder holds); background
processes and `nohup` children stay fenced after the shell exits; a refused write reads
"operation not permitted". Another process's environment is not readable: `KERN_PROCARGS2`
returns the program and its arguments only (also to `ps -wwE`), so an inherited variable can't
mark a job's processes. The kernel's unique process ids (which would survive a parent's exit)
and `sandbox_check` aren't public; parent, session, start time, working folder, and open files
are (`proc_pidinfo`, `proc_pidfdinfo`).

Low-level choices (Claude's):
- **Finding a job's processes**: session, family followed every half second, and users of the
  scratch folder (plan D6), not Endpoint Security (root, an Apple entitlement, Full Disk
  Access). Half a second costs about a millisecond per look and only while a job runs.
- **Scratch folder** in Caches, not `/tmp`: per user, purgeable by macOS, and inside the fence.
- **Fence profile** given inline (`-p`), built per job; no file to clean up. Writes allowed by
  default, not reads or network: the leftovers problem is writes (Toni's scope, no prompt or
  reading controls).
- **Caches allowed without declaring**: `~/Library/Caches` (Homebrew, pip, Xcode), `~/.cache`,
  `~/.npm`; anything else (for example `/opt/homebrew` for `brew install`) is declared.
- **Refused declarations**: `/`, the home folder and folders above it, `~/Library` itself; a
  declaration that broad would switch the fence off.
- **Results looked for** in declared paths and Downloads by modification date since the job
  started; the job's own folder is not listed file by file (a build changes thousands).
- **Watching permanent places** with `DispatchSource` on a handful of folders, not FSEvents on
  the home folder (every change in the home folder would wake the app).

Security review of the first version (2026-10-27): the Jobs folder sat inside the allowed
`~/Library/Caches`, so a command could plant a process record that Latchkey would act on at
the next start; now fenced off except the job's own scratch folder, and start acts only on the
names it gives, never through links. Also raised and left as known gaps (Toni's scope is the
leftovers of ordinary work, not a hostile command): work handed to other programs (launchd,
`open`, Apple events, `defaults`) is outside the fence, and the permanent places are the shell
startup files, launch agents, login items, `~/.ssh`, and git hooks (the last two added by Toni,
2026-10-28), not every place that can run code later (folders on PATH; a project's
`core.hooksPath` setting in `.git/config`, which git itself writes in ordinary work, so it stays
writable; and renaming a project's `.git` folder, or another folder into its hooks folder's place, which
only a hostile command would do; such a command can point git elsewhere through `.git/config`
anyway). Fencing `~/.ssh` means ssh can't add a new server to `known_hosts` from a command
unless declared; it warns and connects anyway. The watcher (FR-325) leaves `~/.ssh` out for that
reason, and doesn't watch git hooks (projects can be anywhere).
