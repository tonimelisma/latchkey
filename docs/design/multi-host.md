# Several machines and Linux servers: design

GOVERNS: `linux/`

Spec 010's plan (migrated from `specs/010-multi-host/plan.md`, titled "Spec 010 plan: several machines and Linux servers — HOW"). What it must do:
[requirements/multi-host.md](../requirements/multi-host.md). Each decision Dn is an ADR, linked
where the decision stood.

Status: written 2026-10-31 and built by 2026-11-01; the maintainer asked for plan and build in one go
("write and implement the plan. don't stop until it's fully done"). Where building changed the
plan (security reviews, test findings), the decision below says so.

Contracts changed: `docs/design/contracts/agent-protocol.md` (sections marked spec 010),
`docs/design/contracts/mcp-surface.md`, new `docs/design/contracts/server-program.md` (the Linux
program's commands, files, install, updates). Data: `docs/design/data-model.md`.

## How Claude uses it (decided 2026-10-31; research.md "End to end")

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

### D1. Several devices per account (FR-1001, FR-1002, FR-1011, FR-1012)

Decision record: [ADR 0112](../adr/0112-several-devices-per-account.md).

### D2. Tool list: union with per-kind notes (FR-1003, FR-1004, FR-1007; decided 2026-10-31)

Decision record: [ADR 0113](../adr/0113-tool-list-union-with-per-kind-notes.md).

### D3. Protocol additions (FR-1002, FR-1009, FR-1020)

Decision record: [ADR 0114](../adr/0114-protocol-additions.md).

### D4. Choosing the machine for a call (FR-1005, FR-1007, FR-1008)

Decision record: [ADR 0115](../adr/0115-choosing-the-machine-for-a-call.md).

### D5. Status line and offline answers (FR-1008, FR-1009; decided 2026-10-31: list the others)

Decision record: [ADR 0116](../adr/0116-status-line-and-offline-answers.md).

### D6. The machines tool and instructions (FR-1006)

Decision record: [ADR 0117](../adr/0117-the-machines-tool-and-instructions.md).

### D7. Headless pairing (FR-1022; RFC 8628's shape)

Decision record: [ADR 0118](../adr/0118-headless-pairing.md).

### D8. The Linux program (FR-1020 to FR-1027; contracts/server-program.md)

Decision record: [ADR 0119](../adr/0119-the-linux-program.md).

### D9. Shell on Linux (FR-1030 to FR-1034)

Decision record: [ADR 0120](../adr/0120-shell-on-linux.md).

### D10. Files on Linux (FR-1040 to FR-1044)

Decision record: [ADR 0121](../adr/0121-files-on-linux.md).

### D11. Activity on Linux (FR-1050, FR-1051)

Decision record: [ADR 0122](../adr/0122-activity-on-linux.md).

### D12. Install, updates, uninstall (FR-1026, FR-1027)

Decision record: [ADR 0123](../adr/0123-install-updates-uninstall.md).

### D13. Mac app (FR-1002, FR-1012)

Decision record: [ADR 0124](../adr/0124-mac-app.md).

### D14. Testing (Constitution VII; decided 2026-10-31: container on this Mac and the Google VM)

Decision record: [ADR 0125](../adr/0125-testing.md).

### D15. Latchkey's log for Claude on Linux (FR-1052 to FR-1056; decided 2026-11-03)

Decision record: [ADR 0126](../adr/0126-latchkeys-log-for-claude-on-linux.md).

### D16. Full traces in daily files (FR-1057 to FR-1059; decided 2026-11-15)

Decision record: [ADR 0127](../adr/0127-full-traces-in-daily-files.md).

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
