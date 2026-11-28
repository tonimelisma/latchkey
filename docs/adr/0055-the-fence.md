# 0055. The fence (FR-317 to FR-320)

- Status: accepted
- Date: 2026-10-27
- Alias: plan 004 D9 (`specs/004-shell/plan.md`, "D9. The fence (FR-317 to FR-320)")

## Context and problem

Decision D9 of spec 004's plan (Shell); requirements in
[requirements/shell.md](../requirements/shell.md). Requirement IDs it cites: FR-317, FR-320, FR-332, FR-318, FR-328, FR-329, FR-333, FR-334, FR-335.
The design it belongs to: [design/shell.md](../design/shell.md).

## Decision


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
check of 2026-10-27. zsh writes its here-documents and `=(…)` to `$TMPPREFIX`, `/tmp/zsh` unless
set, so every one failed until the job got `TMPPREFIX` in its scratch folder (a zsh the command
starts inherits it). zsh's names in `/private/tmp` are not allowed as bash's are: a command
could then overwrite the Owner's own shells' files there (security review 2026-11-03); a zsh
started with `TMPPREFIX` cleared fails as before (bug report 2026-11-03).

Programs macOS stopped (FR-332, 2026-11-03): macOS writes a crash report
(`~/Library/Logs/DiagnosticReports/*.ips`, a one-line header and a JSON body) a few seconds
after the stop, naming the responsible process (Latchkey's pid) and the time it was taken. Each
answer looks at reports written since the job began, taken while it ran, whose responsible pid
is Latchkey's; jobs that finished in the last minute are looked at too, since the report often
comes after their answer, and each report is told once. Options weighed: watching the job's
processes end (no exit status for a grandchild; a quick crash is gone before the next look) and
waiting for the report before answering (seconds on every answer). An app (a program inside a
`.app` bundle) aborts at start inside the fence because LaunchServices is refused: with `uses`
`open` headless Chrome made the PDF in a check on 2026-11-03, once given `--no-sandbox` (Chrome's
own sandbox can't start inside another); `shell_run`'s description and the note say so.
`/usr/bin/log` refuses to run in any sandbox. `cupsfilter` RTF to PDF fails on this macOS
outside the fence too (no filter), so it isn't the fence's. `shell_run` takes `writes` (paths) and `why`;
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
Events refusals and `osascript`'s are always there (decided 2026-10-29): apps refuse Apple
events from any sandboxed program (-10004), so reaching an app would need `osascript` outside
the fence, where it could run anything; 0.8.44 allowed that when `app_scripts` was declared. It always refuses the settings
service (`com.apple.cfprefsd.daemon`, `.agent`): settings are then read from their files, and
`defaults write` writes the domain's file itself, which the fence allows only when declared
("Could not write domain" otherwise), and never for Latchkey's own settings. Allowing the
service when a settings file was declared was the first version; the service writes any domain
for its caller, Latchkey's own included (security review, 2026-10-28). `launchctl submit` and `bootstrap` already fail inside any sandbox. Each refusal adds
its hint to the answer. `shell_run` takes `uses` (a list; `open` is its one value).

Builds (FR-333, FR-334, 2026-11-21): macOS refuses a sandbox inside another
("sandbox_apply: Operation not permitted"), and Apple's build tools start their own: SwiftPM for
package manifests and plugins, Xcode for build scripts and asset symbols, the Swift compiler for
macros (SwiftUI's `@State`). Each job's scratch folder gets `.latchkey/bin/xcodebuild` and
`.latchkey/bin/swift`, put first on the PATH after the login files have run (they reorder it), and
`.latchkey/fence.xcconfig`, named by `XCODE_XCCONFIG_FILE`, which Xcode applies to every build.
`xcodebuild` adds `-IDEPackageSupportDisableManifestSandbox=YES` and
`-IDEPackageSupportDisablePluginExecutionSandbox=YES`; `swift build|test|run|package` adds
`--disable-sandbox`; the settings file sets `ENABLE_USER_SCRIPT_SANDBOXING = NO` and
`SWIFTC_DISABLE_SANDBOX = YES` and `DISABLE_TASK_SANDBOXING = YES` (Core ML model compiles run
in a task sandbox; found building Otos, 2026-11-21). Each job also gets
`IBCLIServerForcedRegistryName=latchkey-<launch>-<job>`: Xcode's asset-catalog daemon
(`ibtoold`) outlives a build and keeps the fence of the job that started it, its pipes live in
the user's shared temporary folder, and an asset-catalog build that picked up a fenced one,
in another job or in the Owner's own Xcode, couldn't write its output; with its own name each
job starts daemons only it uses, stopped with its leftovers. Exporting an app icon made in
Icon Composer (`.icon`) needs LaunchServices, so such a build declares `open` like a package
folder does; its error ("Failed to create a catalog from the Icon Studio document") adds the
`open` hint. Each wrapper runs the next tool of its name on the PATH. The
fence applies to all of it, so what a build may write is unchanged. A program called by full
path (`/usr/bin/xcodebuild`, `xcrun xcodebuild`) gets no wrapper; the answer then says a program
tried a sandbox of its own (FR-334), which is told apart from a refused write by
`sandbox_apply`/`sandbox_init` on the line. Xcode tells a Swift package folder by macOS's file
types, which needs `open` declared; `swift build` doesn't; a project (`.xcodeproj`) needs neither.

Tests (FR-335, 2026-11-21): xcodebuild runs an app's unit tests in the app, which LaunchServices
opens with Xcode's test settings in its environment (`DYLD_INSERT_LIBRARIES`,
`XCTestSessionIdentifier`); for a sandboxed caller macOS opens the app without them, so it starts
as a plain app and xcodebuild gives up ("The test runner hung before establishing connection",
after about six minutes; the same with a sandbox that allows everything). The app carries
`Contents/MacOS/LatchkeyXcodeTests`, a small C program (`macos/XcodeTests/main.c`): it refuses
every argument list without exactly one `test-without-building` or with any other action or
mode (`build`, `test`, `archive`, `-exportArchive`, ...), drops `DYLD_*`, `DEVELOPER_DIR`,
`TOOLCHAINS` and `XCODE_XCCONFIG_FILE`, and starts `/usr/bin/xcodebuild` responsible for
itself (`responsibility_spawnattrs_setdisclaim`, libsystem's, the call macOS's own launchers
use; nothing runs when it is missing), then passes on signals and returns its status: a program
Latchkey starts is otherwise Latchkey's to macOS's privacy checks, and outside the fence it would
write and send Apple Events with Latchkey's permissions (security review 2026-11-21). When the
job declared `open` and no folder above the launcher is writable by the job (else a parent could
be swapped for one holding another program of that name; same review), the profile adds
`(allow process-exec (literal <launcher>) (with no-sandbox))`, as for `ps` and `top`, and
refuses writes inside the `.app` that holds it; the job's `xcodebuild` then turns `test` into
`build-for-testing` (fenced, with the switches above) followed by `test-without-building`
through the launcher, and hands `test-without-building` to it directly. Without `open` the
wrapper refuses tests at once (exit 64) with how to declare it. The test step can then write
anywhere, and so can the tests, which run in an app LaunchServices opened outside the fence
anyway: the reach `open` already grants (the maintainer chose this over running all of xcodebuild outside
and over keeping tests out of Shell, 2026-11-21). A script can't be the launcher: the kernel
starts its interpreter, which stays in the sandbox (checked).

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/LeftoversTests.swift`
- `macos/Tests/ShellTests.swift`
- `macos/XcodeTests/main.c`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
