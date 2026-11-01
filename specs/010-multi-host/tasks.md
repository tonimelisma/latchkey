# Spec 010 tasks

Written with the plan and built in one go (Toni, 2026-10-31). Each ends with its tests passing;
✅ done.

## Protocol (D3)

- **T1001** ✅ Protocol package public (`relay/agentproto`); fixtures `valid/hello-linux.json`,
  `valid/state-linux.json`, `valid/welcome-name.json`, `invalid/hello-bad-kind.json`,
  `invalid/tools-machine-property.json`, `invalid/tools-machines-name.json`, seen failing, then
  hello `kind`/`name`, welcome `name`, state `uptime_s`, reserved `machines` and `machine`.

## Relay (D1, D2, D4 to D7)

- **T1002** ✅ Migration 13 (several devices, `kind`, `device_pairings`); store tests: several
  machines, unique names (Unicode case folding), renaming, device pairing.
- **T1003** ✅ Hub: hello's kind must match the pairing; name from hello kept unique and returned
  in welcome; `clients`/`revoke_client` for Macs only.
- **T1004** ✅ MCP: union of tools with per-kind notes and the `machine` argument, choosing the
  machine, `machines` tool (text only), instructions, state line with the other machines, texts
  naming the machine; unit tests and a real-MCP-client test with a pretend Mac and a pretend server.
- **T1005** ✅ Account: machines list with Remove per machine; pairing adds (`replaces` for the
  same Mac); headless pairing endpoints and `/link` (typed code, wrong-code limit); privacy policy
  and data model.

## Linux program (D8 to D12)

- **T1006** ✅ [P] Settings, device key, tool framework, Files (find, read with PDF/Word/ODT/images,
  change, delete for good, own files protected).
- **T1007** ✅ [P] Shell: terminal jobs, sudo wrapper and prompt detection, delegated control
  groups, leases, Shell's own switch; Linux-only tests in a Debian container with systemd
  (`make test-linux`).
- **T1008** ✅ Connection, activity log and audit check, pairing, service, uninstall, `latchkey`
  command (linked into `~/.local/bin`).
- **T1009** ✅ Signed releases (signature over architecture, version, hash), updater with
  rollback, `install.sh`, `release.sh`.
- **T1010** ✅ End-to-end check `relay/cmd/linuxcheck` (`make -C linux check`): private relay,
  pretend Mac, the program installed with install.sh in a Debian container, real MCP client;
  `-claude` adds real Claude Code.

## Mac app (D13)

- **T1011** ✅ Hello kind and name, welcome name shown, "Name shown to Claude" in Settings,
  pairing again replaces only this Mac, dialog wording, Swift refusals for the new invalid
  fixtures; version 0.8.61.

## Ship

- **T1012** ✅ Deploy the relay; ✅ publish `server-v0.1.0`; ✅ install the app; ✅ live check of the
  Mac through the hosted relay with a fresh Claude Code session. Waiting on Toni's passkey: pair
  his Google VM through the install line (it ran up to the code), then the live check with the Mac
  and the VM together.
