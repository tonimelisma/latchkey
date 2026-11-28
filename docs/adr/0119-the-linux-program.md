# 0119. The Linux program (FR-1020 to FR-1027; contracts/server-program.md)

- Status: accepted
- Date: 2026-10-31
- Alias: plan 010 D8 (`specs/010-multi-host/plan.md`, "D8. The Linux program (FR-1020 to FR-1027; contracts/server-program.md)")

## Context and problem

Decision D8 of spec 010's plan (Several machines and Linux servers); requirements in
[requirements/multi-host.md](../requirements/multi-host.md). Requirement IDs it cites: FR-1020, FR-1027, FR-1021, FR-310, FR-1024, FR-1025, FR-1028.
The design it belongs to: [design/multi-host.md](../design/multi-host.md).

## Decision


Own Go module `linux/` (decided 2026-10-31), binary `latchkey`. The protocol package moves from
relay/internal/agentproto to `relay/agentproto` (public); `linux/go.mod` requires the relay
module with `replace ../relay`. Dependencies: `coder/websocket` (as the relay), the MCP SDK (via
agentproto's `mcp.Tool`), `creack/pty` (terminal), `golang.org/x/image` (resizing), a PDF text
reader (picked in research.md). Nothing else.

- **Service**: `/etc/systemd/system/latchkey.service`, `User=<owner>`, `Delegate=yes`
  (its own control-group subtree, D9), `Restart=always`, `WantedBy=multi-user.target`: starts at
  boot, nobody logged in (FR-1021). Files: program `~/.local/lib/latchkey/latchkey` (owned by the
  Owner, so it can update itself), settings `~/.config/latchkey/settings.json`, data
  `~/.local/share/latchkey/` (device key `device.key` P-256 PKCS#8 0600, `activity/` 0700 with daily files 0600 (D16; `activity.jsonl` of earlier versions kept and read),
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

## Confirmation

The tests that validate the requirements it cites:

- `linux/internal/config/config_test.go`
- `linux/internal/setup/service_test.go`
- `macos/Tests/LevelChangeTests.swift`
- `macos/Tests/ShellTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
