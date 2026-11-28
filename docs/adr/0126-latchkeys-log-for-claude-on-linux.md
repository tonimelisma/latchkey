# 0126. Latchkey's log for Claude on Linux (FR-1052 to FR-1056; decided 2026-11-03)

- Status: accepted
- Date: 2026-11-03
- Alias: plan 010 D15 (`specs/010-multi-host/plan.md`, "D15. Latchkey's log for Claude on Linux (FR-1052 to FR-1056; decided 2026-11-03)")

## Context and problem

Decision D15 of spec 010's plan (Several machines and Linux servers); requirements in
[requirements/multi-host.md](../requirements/multi-host.md). Requirement IDs it cites: FR-1052, FR-1056, FR-1053, FR-1055.
The design it belongs to: [design/multi-host.md](../design/multi-host.md).

## Decision


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
  raw errors, which carry the relay's address, its IP, URLs, host and user names, paths, and
  tokens: public words are never built from an error's message (security review 2026-11-04;
  scrubbing with patterns was dropped, as it misses host names, relative paths, and tokens). They
  name the kind of failure (`agent.describe`: closed by the relay with its code only, timed out,
  name not found, refused, reset, unreachable, certificate refused, dropped; `DescribeUpdate`
  for update checks: GitHub timed out, name, network, certificate, permission denied, disk
  full), and anything else is "an unexpected error (<Go type>)", e.g. `*net.OpError`. The
  log's own read failure is a fixed phrase too. Not connecting names the step that failed (not paired, settings, device
  key), never the error's path.
- New events (FR-1056): started and stopped (`app`), each disconnect with its reason and the
  wait (`connection`; the same reason again before a connection is recorded once), not connecting
  (once per reason), an answer not sent, pause and resume (`pause`), the name changing
  (`settings`), a failed update check (`update`). The journal keeps its `slog` lines.

## Confirmation

The tests that validate the requirements it cites:

- `linux/internal/activity/activity_test.go`
- `linux/internal/agent/log_test.go`
- `linux/internal/latchkeylog/latchkeylog_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
