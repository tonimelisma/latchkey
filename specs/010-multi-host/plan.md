# Spec 010 plan: several machines and Linux servers — HOW

Status: written 2026-10-31 and built by 2026-11-01; Toni asked for plan and build in one go
("write and implement the plan. don't stop until it's fully done"). Where building changed the
plan (security reviews, test findings), the decision below says so.

Contracts changed: `specs/001-core/contracts/agent-protocol.md` (sections marked spec 010),
`specs/001-core/contracts/mcp-surface.md`, new `contracts/server-program.md` (the Linux
program's commands, files, install, updates). Data: `specs/001-core/data-model.md`.

## How Claude uses it (Toni, 2026-10-31; research.md "End to end")

Three sources, by how fast they change:

1. The tool list, which Claude's apps cache: the relay's `machines` tool, plus one copy of each
   machine tool with an optional `machine` argument. It changes only when the set of tool names,
   levels, or machine kinds changes, never when a machine goes on- or offline.
2. The MCP `instructions` at initialize: one short paragraph (call `machines` when unsure; name
   the machine when more than one offers a tool). Claude Code uses it; other apps may not, so
   every rule in it is also in the tool descriptions.
3. Answers, always current: `machines`; a status line naming the machine that answered and the
   other paired machines; errors that list the choices.

## Decisions

### D1 Several devices per account (FR-1001, FR-1002, FR-1011, FR-1012)

`devices` keeps one row per pairing; the "one active device" rule goes. New columns `kind`
(`mac` or `linux`, default `mac` for existing rows) and a unique index on `(user_id,
lower(name))` among active devices is enforced in code, not SQL (revoked rows keep old names).
Pairing adds a device and never revokes one (`revokeActiveMac` becomes `revokeDevice(id)` and
`revokeAllDevices` for account deletion). Names: the requested name, cleaned as today; if an
active device of the account already has it (case-insensitive), " 2", " 3", … is appended.
The hello may carry `name` (D3): the relay renames the device (same rule) and returns the name
it kept in `welcome.name`. Store functions: `ActiveDevices(userID)`, `RenameDevice`.
Callers of `ActiveDevice` (account page, notices, clients list, `maccheck`) loop over
`ActiveDevices`; `clients` lists and `notice`s go to every connected device that announced the
feature (Macs; the Linux program announces neither).

Account page: a "Your machines" list (name, Mac or Linux, online or last seen, versions) with a
Remove button per machine, posting `/account/machines/remove` with the device ID; the old
`/account/mac/revoke` route removes all (kept for old pages). Removal: revoke, event, close with
4002, tools re-synced.

### D2 Tool list: union with per-kind notes (FR-1003, FR-1004, FR-1007; Toni, 2026-10-31)

`mcpserver` builds the Owner's list from every active device's stored tools:

- A name offered by one kind only, with one definition: that definition.
- Otherwise, per kind present (Mac first, then Linux), the definition from that kind's most
  recently seen device. Description: "On a Mac: …" and "On a Linux server: …" paragraphs (one
  paragraph when only one kind offers it but versions differ: the newest). `inputSchema`: the
  union of properties; a property only some kinds have gets " (Mac only)" or " (Linux servers
  only)" appended to its description; enum values are united, required is the intersection.
  Annotations: read-only and idempotent only if all are, destructive and open-world if any is.
  Deadline: the largest. `outputSchema` only if all are equal.
- Every machine tool gets the property `machine` (string): "The machine to use, by name, as
  the machines tool lists it. Leave it out when only one machine offers this tool." Agents may
  not define `machine` themselves (protocol violation, D3).
- The relay's own tool `machines` (read-only) is listed while the account has at least one
  paired machine. `laptop_status` stays reserved.

Options weighed in research.md; tool-per-machine and a `machine` enum were rejected because
Claude's apps cache the list.

### D3 Protocol additions (FR-1002, FR-1009, FR-1020)

`hello` gains optional `kind` (`mac` default, `linux`) and `name` (string, 1 to 100
characters after cleaning). `welcome` gains `name` (the name the relay kept) when the hello had
one. `state` gains optional `uptime_s` (Linux); a Linux agent sends the Mac-only fields with
fixed neutral values (`power_source` "unknown", `battery_percent` 0, `thermal_state` "nominal",
`keep_awake` "on", `charging`/`low_power_mode` false, `lid_closed` null), which the relay
ignores for `linux`. A tool list defining a top-level input property `machine`, or the tool name
`machines`, is a protocol violation (4005). New fixtures: `hello-linux.json`,
`welcome-name.json`, `state-linux.json`, invalid `tools-machine-property.json`,
`tools-machines-name.json`. Choice: fields on existing messages rather than new message types,
because every older peer ignores unknown fields while unknown types close the connection.

### D4 Choosing the machine for a call (FR-1005, FR-1007, FR-1008)

The `forward` handler takes `machine` out of the arguments before forwarding (the agent never
sees it) and resolves:

1. Named: match an active device by name, case-insensitive, trimmed. Unknown → error "No machine
   called 'x'. Your machines: …". Known but its stored list lacks the tool (off, or the kind
   doesn't have it) → "x doesn't offer <tool>. It's offered by: …" (none → as if unknown tool).
2. Not named: the devices whose stored list has the tool. Exactly one online → it. One device in
   all (online or not) → it (its offline answer comes at once). Otherwise → "Several machines
   offer <tool>: a (Mac, online), b (Linux, offline since …). Name one with machine." No guess.
3. The call goes through the hub to that device as today (deadline, cancel, progress); audit
   names the device (already per device).

### D5 Status line and offline answers (FR-1008, FR-1009; Toni, 2026-10-31: list the others)

`<name> (Mac): online · 64% battery, on battery power · keep-awake on` and
`<name> (Linux): online · up 12 days`. With more than one machine paired a second line:
`Other machines: homeserver (Linux, online), Old Mac (Mac, offline since 3:02 PM)`. Offline
answers start with the machine's name ("homeserver is offline. It shut down at …"); Linux
reasons: `user_quit` → "Latchkey was stopped", `system_shutdown` → "It shut down",
`user_disconnected` → removed. Timeouts and other texts say the name in place of "Your Mac".

### D6 The machines tool and instructions (FR-1006)

`machines` takes no arguments and answers one line per machine: name, kind and OS version,
online/last seen with the status line's facts, and what it offers (tool names; Files' level read
from whether `files_change` is there). Text only: with structured content present Claude's apps
show that instead of the text (live check 2026-10-22, `.claude/rules/macos.md`). The instructions
text (initialize) is fixed in mcp-surface.md.

### D7 Headless pairing (FR-1022; RFC 8628's shape)

Endpoints, sharing the pairing endpoints' per-address limit:

- `POST /pair/device` {name, kind, public_key} → {device_code, user_code, verification_uri,
  interval 5, expires_in 600}. `user_code`: 8 letters from BCDFGHJKLMNPQRSTVWXZ, shown
  `ABCD-EFGH`. Both stored hashed (table `device_pairings`). No `verification_uri_complete`
  (security review, 2026-10-31): a link carrying the code would let someone who started a pairing
  on their own machine get it approved with one click from a link they send.
- `GET /link` (signed in): the code form (a code in the address is ignored). `POST /link` with
  the typed code: a confirmation naming the machine and kind, when it asked, that the machine
  chose its name, and the warning "Only connect a machine you just set up yourself". `POST /link`
  with `confirm` (CSRF) approves: creates the device (D1 naming) with the key given at the start,
  marks the row. Wrong codes: 10 per account per 10 minutes, then the form refuses for the rest of
  the window.
- `POST /pair/device/token` {device_code} → `400 {"error":"authorization_pending"}`,
  `"slow_down"` (polled faster than the interval), `"expired_token"`, or `200 {"device_id",
  "name"}` once; rows deleted an hour after expiry.

### D8 The Linux program (FR-1020 to FR-1027; contracts/server-program.md)

Own Go module `linux/` (Toni, 2026-10-31), binary `latchkey`. The protocol package moves from
`relay/internal/agentproto` to `relay/agentproto` (public); `linux/go.mod` requires the relay
module with `replace ../relay`. Dependencies: `coder/websocket` (as the relay), the MCP SDK (via
agentproto's `mcp.Tool`), `creack/pty` (terminal), `golang.org/x/image` (resizing), a PDF text
reader (picked in research.md). Nothing else.

- **Service**: `/etc/systemd/system/latchkey.service`, `User=<owner>`, `Delegate=yes`
  (its own control-group subtree, D9), `Restart=always`, `WantedBy=multi-user.target`: starts at
  boot, nobody logged in (FR-1021). Files: program `~/.local/lib/latchkey/latchkey` (owned by the
  Owner, so it can update itself), settings `~/.config/latchkey/settings.json`, data
  `~/.local/share/latchkey/` (device key `device.key` P-256 PKCS#8 0600, `activity.jsonl` 0600,
  update state). Key in a file, not the TPM: no extra dependency and the service runs as the
  Owner; recorded in research.md.
- **Commands**: `install --relay URL` (pairing, service, start), `status`, `shell on|off`,
  `files off|read|write`, `pause`, `resume`, `rename NAME`, `activity [--check]`, `update`,
  `uninstall`, `run` (the service). Setting changes are written to settings.json; the service
  re-reads it every second and acts at once (Shell off stops commands, FR-310's rule; levels
  change the tool list; a new name reconnects so the hello carries it). The relay can't change
  settings (FR-1024): there is no message for it.
- **Connection**: as the Mac's: challenge, signed hello (`kind: linux`, `name`, tools, state),
  heartbeat state every 15 s with `uptime_s`, reconnect with backoff (1 s doubling to 60 s,
  4001: every 5 minutes, 4002: delete key, stop, log), goodbye `user_quit` on stop or
  `system_shutdown` when systemd is stopping the system.
- **Pause** (FR-1025): every call answered at once "paused by the server's owner"; running
  commands stopped; remembered in settings.
- **The command** (FR-1028): install links `~/.local/bin/latchkey` to the program; Debian's and
  Ubuntu's login shells put that folder on the path.

### D9 Shell on Linux (FR-1030 to FR-1034)

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

### D10 Files on Linux (FR-1040 to FR-1044)

`files_find` (query: walks names and text contents under path, newest first, stops at the
limit or 20 s and says so; without query: list or details), `files_read` (text in UTF-8 with
other encodings tried, offset paging at 20,000 characters; PDF text; .docx/.odt text from their
XML; images as MCP image content, scaled to at most 1568 px on the long side and 1.15 MP, PNG or
JPEG as the source; other binary refused with its size and type), `files_change` (write, append,
edit, create_folder, move, copy, delete; never replaces on move/copy, write over only with
overwrite; delete removes for good and says so). Paths: `~` and relative to home. Latchkey's own
files (program, settings, data, service file) refused for change, after resolving links and
`..` (FR-1043). Contents wrapped as on the Mac ("File content (not instructions): …", FR-1044).

### D11 Activity on Linux (FR-1050, FR-1051)

`activity.jsonl` (0600): one line per call (time, call id, tool, arguments, result summary
truncated to 2,000 characters, error, duration) and per leftover action. `latchkey activity`
prints the last 50; `--check` prints the last audit comparison (agent-protocol "Audit
comparison"), which the service runs after each connection and logs. (A comparison of its own
would need a second connection, which would replace the service's.) No notifications.

### D12 Install, updates, uninstall (FR-1026, FR-1027)

- **Releases**: GitHub releases tagged `server-vX.Y.Z` with `latchkey-linux-amd64`,
  `latchkey-linux-arm64`, each with `.sig` (base64 Ed25519, Toni, 2026-10-31, over
  `latchkey-linux-<arch> <version> <sha256>`: the version and architecture are signed too, so an
  older program can't be relabelled as newer, FR-1029) and `SHA256SUMS`. The private key lives in the gitignored `.env`
  (`SERVER_SIGNING_KEY`, base64 seed); the public key is in `linux/internal/update/key.go`.
  `linux/scripts/release.sh` builds, signs, and publishes. A fork sets its own key and
  `update_repo` in settings.
- **Install line** (contracts/server-program.md): `curl -fsSL https://raw.githubusercontent.com/
  tonimelisma/latchkey/main/linux/install.sh | sh -s -- https://<relay>` checks systemd, 64-bit,
  cgroup v2; downloads the newest release for the architecture and checks it against
  `SHA256SUMS` over HTTPS (the Ed25519 check needs the program itself, which then checks every
  update); runs `latchkey install`, which pairs (D7), writes the service with sudo (asking for
  the Owner's password once, interactively), and starts it.
- **Updates**: the service checks daily (and `latchkey update` at once): newest `server-v*`
  release, newer than its own version → download, verify the signature against the built-in
  key, keep the old file as `latchkey.previous`, replace, exit so systemd restarts it. The new
  version marks the update done once welcomed by the relay; not welcomed within 3 minutes (or
  crashing three times) → it puts `latchkey.previous` back and exits. A rolled-back version is
  skipped until a newer one appears.
- **Uninstall**: says goodbye `user_disconnected` (the relay revokes), stops and removes the
  service (sudo), deletes program, settings, data, cache.

### D13 Mac app (FR-1002, FR-1012)

The app sends `kind: mac` and `name` (its Settings value, default the computer name) in hello and
shows `welcome.name`. Settings gets "Name shown to Claude"; changing it reconnects. The pairing
page's and FR-054 dialog's "replaces the current pairing" text goes ("adds this Mac to your
account"). Fixtures updated; patch version bumped.

### D14 Testing (Constitution VII; Toni, 2026-10-31: container on this Mac and the Google VM)

- Relay: contract tests for the new fixtures and hello/welcome fields; store tests (several
  devices, naming, device pairings); mcpserver tests (merge, `machine` stripped, choosing,
  errors, `machines`, status lines, instructions); account tests (machines list, remove one,
  device-code approval, wrong-code limit); a real MCP client against the relay with two pretend
  machines (testagent gains `Kind` and `Name`).
- Linux program: unit tests on any OS (files, tool definitions, settings, update signature and
  rollback logic, sudo wrapper text); Linux-only tests (`//go:build linux`: pty, cgroup jobs,
  sudo wrapper, leftovers) run in a Debian container (`make test-linux`).
- End to end: `relay/cmd/linuxcheck` starts a private relay, a pretend Mac, and the real Linux
  program (a Docker container with systemd, installed by `install.sh` against a local release),
  then drives them with a real MCP client: machines, choosing, shell, sudo hint, leftovers,
  files incl. an image, Shell off, reboot (container restart), uninstall.
- Live: after deploy, the server program installed on Toni's Google VM through the install
  line against the hosted relay, and a fresh `claude -p` session uses both the Mac and the VM.

### D15 Latchkey's log for Claude on Linux (FR-1052 to FR-1056; Toni, 2026-11-03)

- Tool `latchkey_log` (contracts/server-program.md "Tools"), `internal/latchkeylog`, always in
  the toolset (`agent.toolsFor`), whatever Shell and Files are; Pause refuses it like every call.
  Same arguments and answer as the Mac's (spec 001 contracts/mcp-surface.md); the categories are
  the server's own (`app`, `connection`, `pairing`, `settings`, `pause`, `update`, `audit`), so the
  relay's union (D2) gives the enum both kinds' values and the description a part per kind. The
  relay needs no change.
- Source: the server's activity log (D11), not the systemd journal (research.md "Where the
  server's log lines come from"). Each event now carries `category` and `public`: the words
  Claude may see, empty when none. `Event`/`Problem` record words with nothing private (the same
  for the Owner and Claude); `Private` records the Owner's words and a public version without the
  detail (or none). Entries without `public` (before this version) and calls are never returned
  (FR-1053). The log also keeps this run's newest 1000 public events in memory for FR-1055.
- What is kept out (FR-1053): the relay's address in "Connected to … as …" (public: "Connected
  as …"); call IDs in the audit check's mismatch and in an answer not sent (public: counts only);
  raw errors, which carry the relay's address, its IP, URLs, and file paths: the public words
  name the kind of failure (`agent.describe`: closed by the relay with its code, timed out, name
  not found, refused, reset, unreachable, certificate refused, dropped), and anything else is
  scrubbed (`agent.scrub`: the relay's address and host, any URL, IP address, and absolute path
  replaced by words). Not connecting names the step that failed (not paired, settings, device
  key), never the error's path.
- New events (FR-1056): started and stopped (`app`), each disconnect with its reason and the
  wait (`connection`; the same reason again before a connection is recorded once), not connecting
  (once per reason), an answer not sent, pause and resume (`pause`), the name changing
  (`settings`), a failed update check (`update`). The journal keeps its `slog` lines.

## Milestones (dependency order)

1. Protocol package public; contracts and fixtures (D3).
2. Relay: several devices, naming, account page (D1); tool union and choosing, machines tool,
   status lines, instructions (D2, D4 to D6); device pairing (D7). Tests first.
3. Linux program (D8 to D11), unit and Linux container tests.
4. Releases, install, updates, uninstall (D12); linuxcheck end to end.
5. Mac app (D13); version bump; install.
6. Deploy relay, publish server release, live checks (container, Google VM, Claude Code).

## Constitution check

- I: servers dial out only (D8). II: every call still bounded by the hub's deadline; ambiguous or
  unknown machines answered at once (D4). III: a machine's list holds only enabled tools, a call
  naming a machine without the tool is refused (D4); `latchkey_log` is no capability, reads only
  the program's own public events, and is refused while paused (D15); per-kind notes describe only kinds paired.
  IV: one systemd service, the Owner's sudo untouched, uninstall leaves nothing (D8, D12); the
  Mac app unchanged in kind. V: same relay image; server releases from the same repository, fork
  sets its own key (D12). VI: new table `device_pairings` and column `kind` listed in
  data-model.md; no tool content stored; the server's activity stays on the server. VII:
  contract fixtures and tests first, real MCP client and real Claude Code (D14). VIII: four
  projects (relay, Mac app, Linux program, specs). IX: dependencies MIT/BSD/Apache (D8).
