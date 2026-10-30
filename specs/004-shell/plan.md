# Plan 004: Shell — HOW

Derived from `spec.md`; evidence and low-level choices in `research.md`.

## D1. Tools (level On)

Claude sees consolidated tools (Toni, 2026-10-23: 15 tools in all, from 45): the table below. The operations listed after it are their internals, each reached by an `action` or by which arguments are given.

| Tool | readOnly | destructive | Operations behind it |
|---|---|---|---|
| `shell_run` (command, folder?, wait?, writes?, why?, keep_minutes?; or job + input / stop) | no | yes | run, send, stop |
| `shell_check` (job?, wait?) | yes | no | check; without job, list jobs |

Operations:

| Tool | readOnly | destructive | Serves |
|---|---|---|---|
| `shell_run` (command, folder?, wait?, writes?, why?, keep_minutes?) | no | yes | FR-301, FR-302, FR-307, FR-314, FR-318 |
| `shell_check` (job, wait?) | yes | no | FR-303 |
| `shell_send` (job, text, enter?) | no | yes | FR-303 |
| `shell_stop` (job) | no | yes | FR-303 |
| `shell_jobs` | yes | no | FR-303 |

`shell_run` and `shell_send` declare `openWorldHint` (commands reach the network). Deadline 45 s
(30 s wait plus margin; Claude allows 240 s).

## D2. Running

Each command runs as `/usr/bin/script -q /dev/null /bin/zsh -l -c -- <command>`: `script` gives it
a real terminal session (prompts work, Ctrl-C reaches the program), the login shell loads the
Owner's PATH. Latchkey talks to `script` through pipes; no fork in the app. Environment adds
`TERM=dumb`, `NO_COLOR=1`, `PAGER=cat`, `GIT_PAGER=cat`. Folder: as given, else home (FR-301).
Runs as the Owner's user, never through the helper (FR-306).

## D3. Jobs

A job keeps its output (last 1 MB) and status in memory. Run waits up to `wait` (default and
maximum 30 s) for the end (FR-302). Check returns output since the last check, waiting up to
`wait` for more or the end. Send writes the text (and Enter unless `enter` is false). Stop sends
Ctrl-C, then ends the session after 3 s, then kills it. Finished jobs stay readable for 10
minutes (at most 20 kept). All jobs stop when the app quits (FR-309) and when the Owner turns
Shell off (FR-310): the app first answers any `shell_run` or `shell_check` call in flight with
the reason (spec 001 plan D2), then stops the jobs, all at the same time.

Stopping means the whole terminal session (FR-311): `script` starts the shell as the leader of a
new session, and everything the command starts stays in that session unless it leaves on
purpose. The app notes the session when the job starts (the child of `script` that leads a
session) and, to end a job, signals every process in it and `script` itself: terminate, then
kill whatever is left after 1 s. So a process the command left in the background, or one that
ignores Ctrl-C and hangup, doesn't outlive the job. Since 2026-10-27 a job that ended by itself
is swept too (D6); until then it wasn't, which is how two headless Chrome processes ran for two
days.
A call that is cancelled while waiting on a job (deadline, or Shell turned off) stops waiting at
once.

At most 32 jobs run at once (FR-312); the next `shell_run` is refused with "32 commands are
already running … Wait for one to finish or stop one".

## D4. Output

Control sequences removed; carriage-return redraws keep the last version of the line; at most
50,000 characters per answer, the most recent, saying how much was left out (FR-304, FR-305).

## D5. Levels and visibility

Capabilities gain a list of the levels they offer: shell offers Off and On (On = full use),
starting On (FR-308). `shell_run` returns an `activity` ("Claude ran: …") for the notification
and the trace (FR-307).

## D6. Leftovers are followed and swept (FR-313, FR-324, FR-326)

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

## D7. Leases (FR-314)

`shell_run` takes `keep_minutes` (0 to 1440, default 0). A job's lease ends `keep_minutes` after
the command finished; `shell_check` of the job starts the time again; the end never passes 24
hours after the command finished. A timer every minute ends the leases that are due. A job with
a lease running stays listed past the usual 10 minutes.

## D8. Scratch folder (FR-315, FR-316)

`~/Library/Caches/<app data folder>/Jobs/<launch>-<job>/`, given to the command as `TMPDIR` and
`LATCHKEY_SCRATCH`, so `mktemp`, Python, Node, Go, and Chrome's temporary profiles land there.
Removing a job's leftovers moves the folder to the Trash (`FileManager.trashItem`), or deletes
it when empty. At start, folders of earlier launches are moved to the Trash too (FR-324).

## D9. The fence (FR-317 to FR-320)

Each command runs as `script -q /dev/null /usr/bin/sandbox-exec -p <profile> /bin/zsh -l -c --
<command>`: macOS's sandbox (Seatbelt, as Claude Code, Codex, and Gemini CLI use it), which
applies to the shell and everything it starts, for as long as they run. The profile allows
everything except writes, then allows writes to: `/dev`; the scratch folder; the user's own
temporary folder under `/private/var/folders` (system frameworks need it); Downloads;
`~/Library/Caches`, `~/.cache`, `~/.npm`; the job's folder when it isn't the home folder or above
it, nor `~/Library` itself; each declared path. Later rules win, so it then refuses writes to the permanent places
(`~/.zshrc`, `~/.zprofile`, `~/.zshenv`, `~/.zlogin`, `~/.zlogout`, `~/.bashrc`,
`~/.bash_profile`, `~/.profile`, `~/Library/LaunchAgents`, and the login items folder
`~/Library/Application Support/com.apple.backgroundtaskmanagementagent`, `~/.ssh`, and every
project's `.git/hooks`, submodules' included, by a path pattern in any letter case since a
project can be anywhere and the Mac's disks ignore case; inside the folders a command may write anyway, creating and
deleting the hooks folder and writing git's `*.sample` files as plain files
stay allowed, since `git init` and `git clone` write them and git never runs them) unless declared, and
always to Latchkey's own files (Files' `OwnFiles`) and to the Jobs folder except the job's
own scratch folder: the other jobs' folders and process records are what Latchkey stops and
trashes by at start, where only names it gives (`<launch>-job<n>`, no links) are acted on
(security review, 2026-10-27). `ps` and `top` are started outside the sandbox (macOS won't
start them inside one; they write nothing), and `HOMEBREW_TEMP` points at the scratch folder
(Homebrew's default is `/private/tmp`), and bash's here-document files (`/private/tmp/sh-thd…`,
deleted as soon as read; Homebrew's bash runs without `TMPDIR`) may be written, from the live
check of 2026-10-27. `shell_run` takes `writes` (paths) and `why`;
`~`, the home folder, a folder above it, and `~/Library` itself are refused (FR-318). A refused
write shows as "Operation not permitted"; when the output has it, the answer adds how to write
there (FR-320).

Handing work to macOS (FR-328, FR-329, 2026-10-28): unless `uses` has `open`, the profile
refuses looking up LaunchServices
(`com.apple.coreservices.launchservicesd`, `com.apple.lsd.mapdb`, `.modifydb`, `.open`), so
`open` and apps opened through it fail at once ("Unable to find application", error -10814).
It always refuses the Apple Events service (`com.apple.coreservices.appleevents`), sending
Apple Events, and starting `/usr/bin/osascript` (a script then fails at once, not after a
15-second wait). Since 0.8.45 the Apple
Events refusals and `osascript`'s are always there (Toni, 2026-10-29): apps refuse Apple
events from any sandboxed program (-10004), so reaching an app would need `osascript` outside
the fence, where it could run anything; 0.8.44 allowed that when `app_scripts` was declared. It always refuses the settings
service (`com.apple.cfprefsd.daemon`, `.agent`): settings are then read from their files, and
`defaults write` writes the domain's file itself, which the fence allows only when declared
("Could not write domain" otherwise), and never for Latchkey's own settings. Allowing the
service when a settings file was declared was the first version; the service writes any domain
for its caller, Latchkey's own included (security review, 2026-10-28). `launchctl submit` and `bootstrap` already fail inside any sandbox. Each refusal adds
its hint to the answer. `shell_run` takes `uses` (a list; `open` is its one value).

## D10. What a job left (FR-321, FR-323)

When the leftovers are swept, the answer that reports the end (or the next one) and the activity
log get one Left Behind entry: the processes stopped (by name), the scratch folder moved to the
Trash or kept until when, and the files new or changed since the job started in the declared
paths and in Downloads (at most 20 named, then a count; at most 2,000 entries looked at), each
declared permanent place marked "permanent change". The entry goes to the activity log only
(`EventLog`, `systemLog: false`: it names files, which macOS's log must not, spec 001 FR-620).

## D11. Changes that got past the fence (FR-325)

The permanent places of D9 are watched with `DispatchSource` file-system sources (the home
folder's top level for the startup files, the launch agents folder, the login items folder;
cheap, no recursive watch). A change while a job runs or is kept, at a path no live job
declared, is a Left Behind entry and a notification ("A command Claude ran may have changed …").

## D12. Jobs in every answer (FR-322)

The app appends a text line to every tool result while any job runs or is kept:
`[Shell: job3 running since 14:05; job2's leftovers kept until 15:40 (check job2 to keep them)]`.
It is part of the Mac's result (the relay's state line follows it), so no protocol change.

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

The fence (`sandbox-exec`, deprecated by Apple but working) and the mark (`sandbox_check`, no
public header) are macOS features an update could change without notice, which would leave
writes unfenced or double forks running without any error. At start, before what earlier runs
left is recovered, Latchkey runs `/bin/sh` under a profile that refuses one write and reading a
mark, in a folder `<launch>-check` in the Jobs folder: the write must fail and the program must
be found by its mark within 10 s (3 s failed once under load). The folder, mark, and program are removed at once. A failure
becomes a warning appended to every Shell answer and a Left Behind entry with one notification
(Toni chose to keep Shell running rather than refuse commands, 2026-10-29).
