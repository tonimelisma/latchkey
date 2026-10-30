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
are (`proc_pidinfo`, `proc_pidfdinfo`). Since 2026-10-28 `sandbox_check` is used anyway, for
the one thing nothing public answers (see "Handing work to macOS").

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
`open`, Apple events, `defaults`) is outside the fence (closed 2026-10-28, see "Handing work to
macOS"), and the permanent places are the shell
startup files, launch agents, login items, `~/.ssh`, and git hooks (the last two added by Toni,
2026-10-28), not every place that can run code later (folders on PATH; a project's
`core.hooksPath` setting in `.git/config`, which git itself writes in ordinary work, so it stays
writable; and renaming a project's `.git` folder, or another folder into its hooks folder's place, which
only a hostile command would do; such a command can point git elsewhere through `.git/config`
anyway). Fencing `~/.ssh` means ssh can't add a new server to `known_hosts` from a command
unless declared; it warns and connects anyway. The watcher (FR-325) leaves `~/.ssh` out for that
reason, and doesn't watch git hooks (projects can be anywhere).

## Handing work to macOS (2026-10-28)

Toni chose (2026-10-28) to close the gaps the first version left: opening apps, scripting
other apps, and changing settings now need declaring, and quick double forks are stopped.
Checked on this Mac (macOS 27.0.1), each in a throwaway sandbox:
- `open -a Calculator` under a profile refusing only `com.apple.coreservices.launchservicesd`
  still opened Calculator; refusing `com.apple.lsd.mapdb` stops it ("Unable to find
  application"), `open <url>` fails with -10814, and opening a folder fails at once. `git`,
  `swift`, `swiftc`, `xcrun`, `xcodebuild`, `brew`, `node`, `python3` with ssl, `curl`, `mdfind`,
  `sw_vers`, and `say -o` all work under the full set of refusals.
- `(deny appleevent-send)` alone makes a script to Finder wait two minutes for a timeout;
  refusing `com.apple.coreservices.appleevents` makes it fail in a second, but together with the
  LaunchServices refusal a script to an app waits 15 seconds. So `osascript` itself is refused
  unless `app_scripts` is declared, and `app_scripts` also allows LaunchServices.
- `(deny user-preference-write)` doesn't stop `defaults write` (the settings service doesn't
  check it for this sandbox). Refusing the settings service (`com.apple.cfprefsd.daemon`,
  `.agent`) together with the write fence does: "Could not write domain"; `defaults read` keeps
  working from the files. With the service refused, `defaults write` writes the domain's
  `.plist` itself: a declared file is written, another domain and Latchkey's own (refused by the
  fence) are not, even with the whole folder declared. An app that is running keeps its own
  copy of its settings and may write it back over such a change.
- `launchctl submit` and `launchctl bootstrap` fail inside any sandbox (exit 1, and 5:
  Input/output error) and work outside it, so `brew services` can't start anything from a
  command. Nothing to add.
- A process double-forked out of its session is still in the job's sandbox; `sandbox_check`
  with a path that only this job's sandbox refuses tells it apart from every other process
  (Finder and the Dock: not sandboxed; a sandboxed app that refuses Latchkey's whole folder:
  refuses the scratch folder too).

Low-level choices (Claude's):
- **Finding a job's processes after a double fork**: options were (a) `sandbox_check` with a
  per-job mark, (b) an inherited environment variable, (c) Endpoint Security. (b) can't be read
  back on macOS 27 (above); (c) needs root and an Apple entitlement. (a) can't be shed by the
  process, costs two system calls per process per look, and is a libSystem function without a
  public header (no public way to ask about another process's sandbox exists; Constitution IV
  asks for public APIs where one exists). Chosen: (a), through `App/Shell/SandboxCheck.c`,
  because Swift can't call a C function with variable arguments.
- **The mark**: an empty file `<scratch folder>.mark` in the Jobs folder, which the command can
  neither read nor write; the control is another empty file beside it, `<scratch folder>.open`,
  so a sandbox that judges by kind (file or folder) or by place answers both alike. The scratch
  folder was the first control: the font service's sandbox refuses every file but no folder,
  so it was taken for every job's (live check 2026-10-29).
- **How to declare**: one list, `uses`, next to `writes` (Toni, 2026-10-28); settings through
  `writes` (`~/Library/Preferences`), since they are files there.
- **Refusing `osascript` by path** rather than letting a script time out: other programs that
  send Apple Events (rare) still wait; the hint names the way out.
- **The settings service stays refused** even when a settings file is declared (security review,
  2026-10-28): it writes any domain for its caller, Latchkey's own included.
- **Known gap**: once `open` or `app_scripts` is declared, what the command starts runs outside
  the fence (Terminal told to run a command, a `.command` file opened). Blocking chosen targets
  (Terminal, iTerm) would leave others; declaring is the owner's gate, and the description says
  so (security review, 2026-10-28; Toni's scope is ordinary work, not a hostile command).

Self-check (2026-10-29): Toni chose that a failed check keeps Shell running with a warning
rather than refusing commands (Shell would be unusable after such a macOS update until
Latchkey is fixed). The check costs one short program at start, about 50 ms.
