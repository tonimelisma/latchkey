# Plan 004: Shell — HOW

Derived from `spec.md`; evidence and low-level choices in `research.md`.

## D1. Tools (level On)

Claude sees consolidated tools (Toni, 2026-10-23: 15 tools in all, from 45): the table below. The operations listed after it are their internals, each reached by an `action` or by which arguments are given.

| Tool | readOnly | destructive | Operations behind it |
|---|---|---|---|
| `shell_run` (command, folder?, wait?; or job + input / stop) | no | yes | run, send, stop |
| `shell_check` (job?, wait?) | yes | no | check; without job, list jobs |

Operations:

| Tool | readOnly | destructive | Serves |
|---|---|---|---|
| `shell_run` (command, folder?, wait?) | no | yes | FR-301, FR-302, FR-307 |
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
minutes (at most 20 kept). All jobs stop when the app quits (FR-309).

## D4. Output

Control sequences removed; carriage-return redraws keep the last version of the line; at most
50,000 characters per answer, the most recent, saying how much was left out (FR-304, FR-305).

## D5. Levels and visibility

Capabilities gain a list of the levels they offer: shell offers Off and On (On = full use),
starting On (FR-308). `shell_run` returns an `activity` ("Claude ran: …") for the notification
and the trace (FR-307).

## Testing

Real commands in tests: output and exit status, a non-zero exit, waiting then checking, input to
a `read` prompt, stopping `sleep 100`, folder, login PATH, the output limit; control-code
cleaning on fixed strings; tool list per level.

## Constitution check

| Article | Status |
|---|---|
| I. Outbound only | Pass |
| II. Fail fast | Pass: every call returns within 30 s plus margin; long work continues as a job |
| III. Disabled means nonexistent | Pass |
| IV. Good macOS citizen | Pass: the Owner's own permissions; no root |
| V. Self-hostable | Pass: relay unchanged |
| VI. Store the minimum | Pass: output only in memory, last 1 MB, 10 minutes after the end |
| VII. Test-first | Planned |
| VIII. Simplicity | Pass: system `script` and zsh |
| IX. Open source | Pass |
