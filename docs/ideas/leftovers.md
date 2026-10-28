# Leftovers: making sure Claude's work on the Mac leaves nothing behind

Status: ideas for Toni to pick from (2026-10-27). Nothing here is decided or built.

**Short answer.** Latchkey can't tell junk from a deliverable by looking at a file, so the
waterproof part is not "delete automatically" but "know everything Claude's work touched, and
put it on one list". Processes are the exception: those Latchkey can and should stop on its own,
because it already knows which ones Claude started. So: (1) stop everything a Shell job started,
even after the job has ended; (2) give every Shell job its own scratch folder that is emptied
for it; (3) keep a ledger of everything Claude created and show what still exists; (4) catch the
rest with the Mac's own file-change history. Files Claude was asked to make stay; the list just
says they are there.

## What happened on 2026-10-25 to 27, and why each one slipped through

| Leftover | Why Latchkey didn't catch it |
|---|---|
| Two headless Chrome processes, running two days | A Shell job started them in the background and then ended. Latchkey stops everything in a job's terminal session only when *it* stops the job; the Shell plan says it plainly: "A job that already ended is not swept" (`specs/004-shell/plan.md` D3). The session's own `pkill` missed them. Latchkey knew exactly which session they belonged to. |
| `/tmp/zhvi` (118 MB), `/tmp/bp` (Chrome profiles), `/tmp/pimvault-e2e*.log` | Written by shell commands. Latchkey sees the command text, not the files it writes. macOS's nightly `tmp_cleaner` (a system launch daemon, `com.apple.tmp_cleaner`, run at midnight; this Mac has no `periodic` any more) removes old files in `/tmp` only after days, and never anything outside it. |
| Test images in `~/Pictures/Latchkey` | Latchkey's one-day cleanup there (`MessagesCapability.removeOldCopies`) runs only when the *next* message with an attachment is sent. No later send, no cleanup. |
| Empty "Latchkey Check" folder in Notes | Notes can create a note in a new folder and delete the note, but has no way to delete a folder (`specs/002-notes-messages/spec.md`), so the folder outlives its note. |
| Safari windows or tabs (possibly) | Browser reuses one remembered window and adds tabs to it (`specs/005-browser/plan.md`); nothing ever closes them. |
| Wanted: `~/Downloads/benepass` receipts, `~/.config/pimvault-e2e-key.json` | These look the same to a machine as the junk: new files, written by a shell command, from the same sessions. This is why "delete everything Claude made" is wrong. |

Three patterns: Latchkey's own cleanups wait for an event that may never come; Shell jobs can
outlive their own bookkeeping; and file writes by commands are invisible to Latchkey today.

## Shortlist (ranked)

### 1. Sweep a Shell job's leftovers when it ends, not only when it is stopped

When a job's command exits, look for processes still in its terminal session, and (new) any
process carrying the job's tag (below), anywhere. Then either stop them at once, or keep them
running but list them as "still running from Claude's job …" with one-click stop, and stop them
when Claude's conversation ends (the relay already ends a Claude session after 30 minutes
without a request, spec 001 FR-090). Which of the two is for Toni to pick.

The tag: add `LATCHKEY_JOB=<id>` to each job's environment. Every program the command starts
inherits it, including ones started with `nohup`, `setsid`, `&`, or a double fork, which leave
the terminal session but keep the environment. The Mac app can read the environment of the
Owner's own processes (the same thing `ps -E` shows, via `sysctl(KERN_PROCARGS2)`; checked on
this Mac). It's lost only if a program clears its environment, or when a command asks launchd
or LaunchServices to start something (`open -a`, `launchctl`, `brew services`), which starts it
fresh.

- Catches: the Chrome incident exactly, dev servers, watchers, `nohup` jobs, anything forked off.
- Misses: things handed to launchd (`open -a Safari`, `brew services start`), login items and
  launch agents a command installs (see idea 9 for those).
- Effort: small. The session sweep exists; it needs a trigger at job end, a timer that rescans
  `proc_listallpids` every minute or so, and the environment check.
- Risks: stopping a server Claude started on purpose for Toni ("run a local web server I can
  keep using"). An explicit `keep` on `shell_run` (Claude says so, Toni sees it in the list) or
  the "stop when the conversation ends" variant handles that. No privacy cost.

### 2. A scratch folder per Shell job, emptied for it

Each job gets its own folder, for example `~/Library/Caches/Latchkey/jobs/<job id>/`, with
`TMPDIR` pointing into it, so `mktemp`, Python's `tempfile`, Go, Node, and Chrome's temporary
profiles land there instead of `/tmp`. The tool description tells Claude to put scratch work in
`$LATCHKEY_SCRATCH` ("emptied after the job; put deliverables where the Owner asked"). Latchkey
removes the folder some time after the job ends (an hour, or when the conversation ends), and
also at every app start for folders whose job is gone, so cleanup never depends on a later
event.

This is what other agent tools do: Codex CLI's sandbox allows writes to the working folder and
`$TMPDIR`; Claude Code's sandbox to the working folder; and the cleanest agents (Anthropic's
computer-use reference, Devin, OpenHands) work in a throwaway container or VM, which Latchkey
can't do on Toni's real Mac but can imitate for scratch space.

- Catches: most temporary files, Chrome profiles, downloads to a temp folder, build outputs, and
  anything Claude chooses to put in scratch (which it will, once told it is cleaned).
- Misses: literal paths like `/tmp/zhvi` that ignore `TMPDIR` and the hint. Idea 4 lists those.
- Effort: small.
- Risks: a deliverable put in scratch by mistake is deleted. Moving the folder to the Trash
  instead of erasing (as Files does, FR-203) makes that recoverable. Also fix the same "only on
  the next event" bug in `~/Pictures/Latchkey`: clean it on a timer and at app start.

### 3. A ledger of everything Claude created, with "what's still there"

Every tool other than Shell knows exactly what it creates: Files (paths), Notes (note and folder
ids), Calendar events, Reminders, Contacts, Browser tabs, Messages attachments copied to
Pictures. The activity log already records each call with its result, forever. Add a small
"Made by Claude" list in the Activity window: every created thing, grouped by Claude app and
conversation, with whether it still exists (checked when the list opens), and buttons "Keep" and
"Move to Trash". The relay's call id (FR-632) and the Claude app's name (FR-637) are already on
each entry, so grouping costs little more than the relay also passing its session id.

Small extras that make it trustworthy:
- Put a Finder tag "Claude" (and an extended attribute with the call id) on every file the Files
  tool writes, so Toni can see and sort them in Finder and Spotlight finds them all
  (`mdfind "kMDItemUserTags == Claude"`).
- Let Notes delete an empty folder it created, and close the Safari tabs Browser opened after the
  conversation ends (both small tool changes).
- Run the ledger check at each live test, so Latchkey's own checks prove they leave nothing.

- Catches: everything made through Latchkey's own tools, exactly, with no guessing.
- Misses: everything a Shell command makes (ideas 2 and 4 cover that).
- Effort: medium (one list, one "still exists?" check per kind of thing).
- Risks: low. The list holds only names and ids already in the encrypted log. Deleting stays
  Toni's click (or Claude's, through the normal tools).

### 4. Files changed during a Shell job, from macOS's own change history

macOS keeps a running record of which folders changed on each disk (FSEvents), and an app can
ask for everything since a numbered point. Note the record's number when a job starts and when
it ends; afterwards, ask for the folders that changed in between, then list the files in them
whose creation time falls inside the job (one `stat` per file). Filter out noise (other apps'
caches, Latchkey's own scratch, Spotlight, Mail), and add the rest to the ledger as "probably
made by Claude's job … (Toni or other apps may also have written here)".

- Catches: `/tmp/zhvi`, `/tmp/bp`, the log files, and the wanted receipts and key file too,
  listed so Toni decides, not deleted.
- Misses: which *process* wrote a file (FSEvents doesn't say), so while a job runs, Toni's own
  work in the same folders shows up as well. Replaying history gives folders, not files (Apple's
  header: file-level detail "has no effect on historical events"), hence the per-file check.
  Jobs that run for days produce long lists.
- Effort: medium. Public API, no root, no new permission for folders the app can already read;
  privacy-protected folders need Full Disk Access to inspect.
- Risks: false positives (honest wording handles that: "changed while the job ran"). Privacy: it
  stores file paths, which the log already holds for Files calls; keep it inside the encrypted
  log.

### 5. One "Claude left behind" summary, delivered where Toni looks

Put ideas 1 to 4 into one view and one notification: after a conversation ends (relay session
closed), the Mac sends "Claude's session from Claude on iPhone, 14:05 to 14:40: 2 processes
still running, 3 files in /tmp (120 MB), 1 Notes folder. Review…". The same summary could be a
tool result Claude sees (`laptop_status` or a new `cleanup_list`), so Claude cleans up after
itself before the conversation ends, and the Mac state line already shown in every result can
say "3 leftovers from earlier sessions".

- Catches: nothing new by itself; it turns the other ideas into something Toni actually sees.
- Effort: small once 1 to 4 exist.
- Risks: notification fatigue if noisy; show it only when the list isn't empty.

## The long list

### Processes

| Idea | Catches | Misses | Effort | Risks |
|---|---|---|---|---|
| Sweep the job's terminal session at job end (idea 1, part a) | Background children like the Chrome processes | Anything that called `setsid` | Tiny | Stops a server Claude meant to keep |
| Environment tag `LATCHKEY_JOB` (idea 1, part b) | Also `setsid`, `nohup`, double forks | launchd/LaunchServices starts; programs that clear the environment | Small | Same |
| Run each job as a launchd job (the app submits it) with `AbandonProcessGroup` off | launchd kills the job's process group when the job dies (`man launchd.plist`); a second, system-enforced net | Processes that change process group | Small to medium | Changes how jobs start; must keep the terminal behavior (FR-304) |
| Listen for exits with `kqueue` `EVFILT_PROC` `NOTE_EXIT` on the job's processes | Instant sweep instead of a timer | Same as above | Small | None |
| "Running from Claude" section in the menu | Toni sees any of the above at a glance | | Small | |
| Stop leftovers when the conversation ends (relay tells the Mac the session closed) | Long-lived helpers Claude forgot | Work Claude meant to outlive the chat (needs a `keep`) | Small (relay message + contract) | Kills wanted servers if `keep` is forgotten |
| Endpoint Security (Apple's security-monitoring API): exact fork/exec/exit and file create/rename/delete per process | Everything, with which process did it | Nothing on disk or in processes | Large: needs an Apple-granted entitlement, a system extension, root, and Full Disk Access | Heavy, privileged, a big new attack surface; Apple may refuse the entitlement |
| `eslogger` (Apple's command-line Endpoint Security logger, macOS 13+) run by the root keep-awake helper, filtered to the job's processes | Same as above without the entitlement | | Medium | Gives the root helper a new role (FR-306 keeps Shell away from it); needs Full Disk Access for the helper; output contains every file path |

### Files

| Idea | Catches | Misses | Effort | Risks |
|---|---|---|---|---|
| Scratch folder + `TMPDIR` per job (idea 2) | Temporary files of well-behaved tools | Literal `/tmp/...` paths | Small | Deliverable put in scratch: use the Trash |
| Fix cleanups that wait for "the next time" (Pictures/Latchkey): timer + app start | The test images | | Tiny | None |
| Shell's default folder becomes the scratch folder instead of home | Files written with relative paths | Absolute paths | Tiny | Surprises commands that expect home; Claude can still pass a folder |
| FSEvents history per job (idea 4) | All new files during the job, anywhere | The writer's identity | Medium | Noise from Toni's own work |
| `find` over the likely places (`/tmp`, `~`, `~/Downloads`, `~/.config`, `~/Library/Caches`) for files created during the job | Same, more simply, with exact files | Slow over a large home; misses places not searched | Small | Disk load on long jobs |
| Spotlight query for files created in the job's time window | Visible places (Documents, Desktop, Downloads) quickly | Spotlight skips `/tmp`, hidden folders, most of Library | Tiny | |
| Seatbelt sandbox (`sandbox-exec`, what Codex and Claude Code use) limiting a job's writes to scratch + chosen folders | Stray writes are refused, not just listed | | Medium | Breaks real work (git in a repo, Homebrew, Downloads) unless Claude asks for folders; `sandbox-exec` is deprecated though still shipped |
| APFS local snapshot at job start (`tmutil localsnapshot`), compare with the snapshot afterwards | Every change, and an undo for everything | | Large: no public "diff" API, comparing a whole disk is slow | Snapshots hold deleted data and disk space |
| Finder tag "Claude" + call-id attribute on files the Files tool writes | Makes Claude's files visible in Finder and Spotlight | Shell-written files (unless FSEvents results are tagged too) | Tiny | Tags sync over iCloud Drive |
| Size alarm: any new file over, say, 50 MB in the job's window gets its own line | `/tmp/zhvi`-style bulk downloads | | Tiny on top of FSEvents | |

### Things in apps

| Idea | Catches | Misses | Effort |
|---|---|---|---|
| Ledger of created notes, folders, events, reminders, contacts (idea 3) | Everything made through those tools | Edits to Toni's existing items (the log shows those) | Medium |
| Notes: allow deleting an empty folder Claude created | The "Latchkey Check" folder | | Tiny |
| Browser: close Claude's window, or its tabs, when the conversation ends; or close tabs not looked at for an hour | Leftover Safari tabs | Tabs Toni opened in that window himself | Small |
| Messages attachments: delete the copy once Messages reports it sent | The Pictures folder entirely | | Small |
| Live checks name everything they make with a fixed prefix (for example "Latchkey test") and end by asserting the ledger is empty | Latchkey's own tests leaving things | | Tiny |

### Telling junk from deliverables

No rule is waterproof; a few signals together make a good default order for the list:

- Where it is: `/tmp`, caches, scratch, hidden tool folders lean junk; Downloads, Documents,
  Desktop, iCloud Drive, `~/.config` lean deliverable (the receipts and the key file were in
  those).
- What it is: browser profiles, `.log`, partial downloads, lock files lean junk; PDFs, images
  sent to Toni, documents lean deliverable.
- Whether a later tool call used it (read it, attached it, opened it): leans deliverable.
- Claude says so: an optional `keep` / "this is the result" note on `shell_run`, shown in the
  list. Claude's word only decides the order and the label, never deletes anything.

The list shows everything either way; the signals decide what's preselected for "Move to Trash".

### Bold ones

- **A throwaway Mac for Claude's scratch work.** Apple's Virtualization framework runs a macOS
  virtual machine on Apple silicon; Shell jobs that don't need Toni's files run there and the VM
  resets after each conversation. Truly leaves nothing, at the price of a 20-plus GB disk image,
  minutes to start, and a second "Mac" that isn't Toni's.
- **A separate macOS user for Shell.** Commands run as a "latchkey-claude" user who can read
  Toni's files through a group but writes only to its own home, which can be wiped. Strong
  separation, but breaks anything that needs Toni's logins, keychain, or Homebrew.
- **Claude cleans up itself, on schedule.** When a conversation goes quiet, the relay sends the
  leftover list to Claude as part of its last results, and Claude removes its own scratch through
  the normal tools. Cheap, but depends on Claude.
- **Undo for a whole conversation.** Combine the ledger, the scratch folders, the Trash, and an
  APFS snapshot into "Undo everything Claude did between 14:05 and 14:40". Very appealing, very
  hard to make safe for anything that left the Mac (sent messages, web forms).

## Sources

- Latchkey: `specs/004-shell/plan.md` (D3 "A job that already ended is not swept"),
  `specs/001-core/spec.md` (FR-090, FR-610 to FR-637), `specs/002-notes-messages/plan.md`
  (attachments in `~/Pictures/Latchkey`), `macos/App/Messages/MessagesCapability.swift`
  (`removeOldCopies`, run only from `stage`), `specs/005-browser/plan.md`.
- launchd's process-group cleanup: `man launchd.plist`, key `AbandonProcessGroup` ("When a job
  dies, launchd kills any remaining processes with the same process group ID as the job"); see
  also [leancrew's copy](https://leancrew.com/all-this/man/man5/launchd.plist.html).
- FSEvents history and its limits: [Apple, Using the File System Events
  API](https://developer.apple.com/library/mac/DOCUMENTATION/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html);
  the `FSEvents.h` header on `kFSEventStreamCreateFlagFileEvents` and historical events (quoted in
  [fsevent-sys](https://docs.rs/fsevent-sys/5.2.0/src/fsevent_sys/fsevent.rs.html)).
- Endpoint Security and `eslogger` (root, Full Disk Access): [eslogger(1)](https://keith.github.io/xcode-man-pages/eslogger.1.html),
  [Apple Developer Forums on FDA for daemons](https://developer.apple.com/forums/thread/804548),
  [Cybereason, Blue teaming with eslogger](https://www.cybereason.com/blog/blue-teaming-on-macos-with-eslogger).
- How other agent tools contain their files: [Codex sandboxing](https://developers.openai.com/codex/concepts/sandboxing)
  (Seatbelt; working folder and `$TMPDIR` writable), [Claude Code sandboxing](https://code.claude.com/docs/en/sandboxing)
  (Seatbelt; working folder writable; Bash only).
- `/tmp` cleanup: this Mac has `com.apple.tmp_cleaner` (a launch daemon at midnight) and no
  `/etc/periodic`; older macOS used `periodic`'s 3-day rule ([Apple Developer Forums
  71382](https://developer.apple.com/forums/thread/71382)).
- Reading another same-user process's environment: `ps -wwE` on this Mac shows a child's
  `LATCHKEY`-style variable (checked 2026-10-27).
