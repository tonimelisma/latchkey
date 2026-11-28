# Core: connect Claude to the Mac: design

GOVERNS: `relay/` `macos/App/` `macos/Helper/` `macos/Shared/`

Spec 001's plan (migrated from `specs/001-core/plan.md`, titled "Plan 001: Core — HOW"). What it must do:
[requirements/core.md](../requirements/core.md). Each decision Dn is an ADR, linked
where the decision stood.

Derived from `docs/requirements/core.md`. Every decision names the requirement(s) it serves. Evidence is in
`docs/research/2026-10-19-core.md`.

## Architecture

```
Claude (web / Desktop / iOS / Android)          Anthropic's cloud calls the relay; egress 160.79.104.0/21
        │  HTTPS, MCP Streamable HTTP, OAuth 2.1 bearer token
        ▼
┌──────────────────────────── Relay (Go, one binary, SQLite) ────────────────────────────┐
│  /mcp            MCP server: handshake, tools/list (cached), laptop_status, forwarding   │
│  /.well-known/*  OAuth discovery (RFC 9728 protected resource, RFC 8414 auth server)    │
│  /authorize /token /register   OAuth authorization server (zitadel/oidc)                 │
│  /account        Web pages: sign-up, passkey sign-in, recovery, revoke, delete, audit    │
│  /agent/v1       WebSocket endpoint the Mac app dials into                               │
│  Hub: in-memory map device_id -> live connection; deadlines; offline answers            │
└──────────────────────────────────────────────────────────────────────────────────────────┘
        ▲  WSS, outbound from the Mac (contracts/agent-protocol.md)
        │
┌──────────────── Mac app (Swift, menu bar) ────────────────┐
│  Connection: URLSessionWebSocketTask, NWPathMonitor, wake  │
│  Power monitor: IOKit power sources, thermal state         │
│  Capabilities: System info -> battery_status               │
│  Settings: relay URL, capabilities; local tool-call trace  │
│        │ XPC (code-signing-checked)                         │
│  Helper daemon (root, SMAppService): sleep on/off only     │
└────────────────────────────────────────────────────────────┘
```

## Decisions

### D1. NAT traversal: the Mac app keeps one outbound WebSocket to the relay

Decision record: [ADR 0002](../adr/0002-nat-traversal-the-mac-app-keeps-one-outbound-websocket-to.md).

### D2. The relay is the MCP server, not a pass-through

Decision record: [ADR 0003](../adr/0003-the-relay-is-the-mcp-server-not-a-pass-through.md).

### D3. Deadlines

Decision record: [ADR 0004](../adr/0004-deadlines.md).

### D4. OAuth authorization server: zitadel/oidc plus Claude's client registration methods

Decision record: [ADR 0005](../adr/0005-oauth-authorization-server-zitadel-oidc-plus-claudes-client.md).

### D5. Owner authentication: passkeys only, email recovery

Decision record: [ADR 0006](../adr/0006-owner-authentication-passkeys-only-email-recovery.md).

### D6. Pairing: browser sign-in, Secure Enclave device key

Decision record: [ADR 0007](../adr/0007-pairing-browser-sign-in-secure-enclave-device-key.md).

### D7. Keep-awake: SMAppService helper daemon

Decision record: [ADR 0008](../adr/0008-keep-awake-smappservice-helper-daemon.md).

### D8. Power and thermal monitoring

Decision record: [ADR 0009](../adr/0009-power-and-thermal-monitoring.md).

### D9. Mac app packaging

Decision record: [ADR 0010](../adr/0010-mac-app-packaging.md).

### D10. Relay implementation

Decision record: [ADR 0011](../adr/0011-relay-implementation.md).

### D11. Audit log and local trace

Decision record: [ADR 0012](../adr/0012-audit-log-and-local-trace.md).

### D12. Apps with access: one row per approval, pushed to the Mac

Decision record: [ADR 0013](../adr/0013-apps-with-access-one-row-per-approval-pushed-to-the-mac.md).

### D13. Terms and privacy policy, from the operator's settings

Decision record: [ADR 0014](../adr/0014-terms-and-privacy-policy-from-the-operators-settings.md).

### D14. Operator commands in the relay binary; the running relay follows the database

Decision record: [ADR 0015](../adr/0015-operator-commands-in-the-relay-binary-the-running-relay.md).

### D15. Menu bar: state in the icon's shape, a short menu, a Settings window, Pause

Decision record: [ADR 0016](../adr/0016-menu-bar-state-in-the-icons-shape-a-short-menu-a-settings.md).

### D18. Relay audit trail

Decision record: [ADR 0017](../adr/0017-relay-audit-trail.md).

### D17. Unsettled states, and the installer's checks of the running app

Decision record: [ADR 0018](../adr/0018-unsettled-states-and-the-installers-checks-of-the-running.md).

### D16. Diagnostic log in macOS's unified log

Decision record: [ADR 0019](../adr/0019-diagnostic-log-in-macoss-unified-log.md).

### D19. Mac audit trail

Decision record: [ADR 0020](../adr/0020-mac-audit-trail.md).

## Repository layout

```
latchkey/
  docs/adr/0001-constitution.md
  docs/requirements/core.md/...
  relay/                      Go module
    cmd/relay/main.go
    internal/hub/             live device connections, deadlines, offline answers
    agentproto/               message types (public since spec 010; was internal/agentproto) for contracts/agent-protocol.md
    internal/mcpserver/       MCP surface, laptop_status, forwarding
    internal/oauth/           zitadel/oidc wiring, token storage, CIMD, DCR, metadata
    internal/account/         passkeys, recovery, pairing, web pages
    internal/store/           SQLite schema and queries
    internal/server/          assembles the parts into one http.Handler (used by cmd/relay and tests)
    internal/testagent/       pretend Mac speaking the agent protocol (tests and local checks)
    internal/e2e/             headless Chrome with a virtual passkey, OAuth and pairing helpers
    cmd/localcheck/           the Claude Code check (scripts/claude-code-check.sh)
    Dockerfile
  macos/
    project.yml               XcodeGen definition (generates Latchkey.xcodeproj, not committed)
    App/                      menu bar UI, connection, power monitor, capabilities
    Helper/                   privileged daemon, XPC listener
    Shared/                   XPC protocol, agent protocol types
```

## Testing strategy (Constitution VII)

- Contract tests first, failing before implementation:
  - Agent protocol: a Go test agent that speaks `docs/design/contracts/agent-protocol.md`, including bad
    signatures, missed heartbeats, late results, and replaced connections.
  - MCP surface: go-sdk client against the relay; offline, timeout, and list-changed cases.
  - OAuth: full authorization code + PKCE flow with CIMD and with DCR; refresh rotation; bad
    redirect URIs; `401` discovery headers.
- Shared fixtures: one JSON example per agent protocol message in `contracts/fixtures/`, read by
  both the Go and the Swift tests so the two sides cannot drift.
- Mac app: unit tests for the keep-awake state machine (inputs: power source, battery %,
  thermal state, user setting; output: on/off plus reason).
- Mac app, level changes (FR-066): slow stand-in tools running as calls; lowering the level
  answers the write with the reason and leaves the read running; raising stops nothing; the
  program a cancelled call waits on ends. State reports (FR-036a): the decision function on
  fixed times. Pairing links (FR-054a, FR-054b): the one-at-a-time gate and link parsing with
  and without local addresses. Helper (D7): no connection without a requirement, and the test
  app itself (a Debug build) fails the Release requirement. Identity (FR-074): the Release names
  are pinned string by string, the development names share none of them, the test app's bundle on
  disk carries the development identifier, scheme, and helper plist, the helper plist template
  yields the shipped file for Release, and `project.yml` agrees with the code.
- Browser sign-in: an automated test drives headless Chrome with a virtual passkey through the
  real sign-up, sign-in, consent, and pairing pages, using `github.com/chromedp/chromedp` (MIT).
  Runs in any container with Chrome.
- Claude Code check, run by Claude, not decided: Claude Code in non-interactive mode (`claude -p` with
  an MCP config carrying an access token obtained by the automated browser sign-in) against a
  local relay plus the paired Go test agent, asking for the battery.
- Real Claude on web, Desktop, and phone through a public test deployment (quickstart checklist).
  Hosting decided at M4.
- No manual testing by the maintainer; he is asked only for steps that need his accounts or devices.
- No hardware test runs for keep-awake (decided 2026-10-20); SC-06 is checked in normal use.

## Milestones

Pairing comes before the Mac app, so the app connects the real way from its first build (decided
2026-10-20).

| # | Milestone | Proves |
|---|---|---|
| M1 | Relay hub + agent protocol with Go test agent | D1, D3, FR-010 to FR-013 |
| M2 | OAuth + passkeys + pairing (relay side) | D4, D5, D6 |
| M3 | Mac app: pairs, connects, keeps awake, answers `battery_status` | D6, D7, D8, D9 |
| M4 | End to end from Claude on phone, web, Desktop | FR-001, SC-02, SC-03, SC-07 |
| M5 | Packaging: signing, notarization, Sparkle, Docker image | FR-072, FR-080 |

### D20. Every permission at first run (FR-623, FR-606)

Decision record: [ADR 0021](../adr/0021-every-permission-at-first-run.md).

### D21. macOS's monthly screen question while the Owner is here (FR-624)

Decision record: [ADR 0022](../adr/0022-macoss-monthly-screen-question-while-the-owner-is-here.md).

### D22. Missing permissions named in Claude's answer (FR-625)

Decision record: [ADR 0023](../adr/0023-missing-permissions-named-in-claudes-answer.md).

### D23. A lost permission is told to the Owner (FR-626)

Decision record: [ADR 0024](../adr/0024-a-lost-permission-is-told-to-the-owner.md).

### D24. Never stop reconnecting; one copy at a time (FR-206, FR-207)

Decision record: [ADR 0025](../adr/0025-never-stop-reconnecting-one-copy-at-a-time.md).

### D25. Add Latchkey to Claude (FR-627, FR-628, FR-659, FR-660)

Decision record: [ADR 0026](../adr/0026-add-latchkey-to-claude.md).

### D27. No call missing because the app stopped (FR-666 to FR-668)

Decision record: [ADR 0027](../adr/0027-no-call-missing-because-the-app-stopped.md).

### D26. Latchkey's log for Claude (FR-662 to FR-665)

Decision record: [ADR 0028](../adr/0028-latchkeys-log-for-claude.md).

### D28. Full traces in daily files (FR-680 to FR-689; spec 010 FR-1057 to FR-1059)

Decision record: [ADR 0029](../adr/0029-full-traces-in-daily-files.md).

### D29. The hosted relay's server: locked down and watched (2026-11-21)

Decision record: [ADR 0030](../adr/0030-the-hosted-relays-server-locked-down-and-watched.md).

## Constitution check

| Article | Status |
|---|---|
| I. Outbound only | Pass (D1) |
| II. Fail fast | Pass (D2, D3; security emails are sent after the change, with a deadline, D5); hosted Claude timeout to be measured |
| III. Disabled means nonexistent | Pass (FR-061); Pause leaves levels as they are and answers calls like an offline Mac (D15); `latchkey_log` is no capability, reads only Latchkey's own public lines, and is refused while paused (D26) |
| IV. Good macOS citizen | Pass with one documented exception: no App Sandbox (D9) |
| V. Self-hostable | Pass (D10) |
| VI. Store the minimum | Pass as amended on 2026-11-15 (D11, D12, D14, D28, data-model.md): a grant's label and times, the operator's own actions for a year, and each account's full trace, encrypted, in its own files until the account is deleted, never in the database |
| VII. Test-first | Planned (testing strategy) |
| VIII. Simplicity | Pass: relay, Mac app, specs |
| IX. Open source | Pass: Apache-2.0; all dependencies MIT, BSD, or Apache |
