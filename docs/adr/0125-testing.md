# 0125. Testing (Constitution VII; decided 2026-10-31: container on this Mac and the Google VM)

- Status: accepted
- Date: 2026-10-31
- Alias: plan 010 D14 (`specs/010-multi-host/plan.md`, "D14. Testing (Constitution VII; decided 2026-10-31: container on this Mac and the Google VM)")

## Context and problem

Decision D14 of spec 010's plan (Several machines and Linux servers); requirements in
[requirements/multi-host.md](../requirements/multi-host.md). Requirement IDs it cites: none current.
The design it belongs to: [design/multi-host.md](../design/multi-host.md).

## Decision


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
- Live: after deploy, the server program installed on the maintainer's Google VM through the install
  line against the hosted relay, and a fresh `claude -p` session uses both the Mac and the VM.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
