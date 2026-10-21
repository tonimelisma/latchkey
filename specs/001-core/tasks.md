# Tasks 001: Core

Derived from `plan.md` and `contracts/`. Ordered by milestone; within a milestone, top to bottom.
`[P]` = can run in parallel with the other `[P]` tasks of the same group (different files, no
dependency). Every task names the requirements or decisions it serves and says when it is done.

Test-first (Constitution VII): a task marked **(test first)** writes tests that must be run and
seen failing before the implementation task after it starts.

Shared contract fixtures live in `specs/001-core/contracts/fixtures/` (one JSON file per agent
protocol message). Both the Go and the Swift tests read them (plan, testing strategy).

Order (plan, milestones): relay first, then sign-in and pairing on the relay, then the Mac app,
which pairs the real way from its first build. No keep-awake spike or hardware test runs.

---

## M1: Relay hub and agent protocol, Go test agent

Package directories are created when they get code, not up front (T010).

- **T010** ✅ Go module `relay/` (`github.com/tonimelisma/latchkey/relay`), `cmd/relay/main.go`
  reading the D10 environment config, and the package directories from the plan's layout. Add
  `go test ./...` and run commands to CLAUDE.md. *Serves D10.*
- **T011** ✅ Contract fixtures: `contracts/fixtures/*.json` for every message in
  `agent-protocol.md` (challenge, hello, welcome, state, tools, progress, result, goodbye, call,
  cancel, notice), plus invalid examples (unknown type, tool named `laptop_status`).
  *Serves Constitution VII.*
- **T012** ✅ [P] **(test first)** `internal/agentproto` tests: every fixture round-trips; unknown
  fields are ignored; unknown types and colliding tool names are rejected; `deadline_ms` is capped
  at 60000; the signature input is built exactly as the contract says.
- **T013** ✅ [P] **(test first)** `internal/store` tests for the M1 tables: `users`, `devices`,
  `device_state`, `audit_log` (`data-model.md`).
- **T014** ✅ Implement `internal/agentproto` and `internal/store` (SQLite via `modernc.org/sqlite`,
  schema migrations). *Done when T012 and T013 pass.*
- **T015** Go test agent `internal/testagent`: dials `/agent/v1`, signs the challenge with a P-256
  key, sends tools and state, answers calls through pluggable handlers (delay, error, never answer,
  late answer), and can send bad signatures, skip heartbeats, and send oversize frames. Tests
  register its key directly in the store.
- **T016** **(test first)** Agent protocol contract tests using the test agent against an
  `httptest` relay. Clock and timeouts injectable so tests run fast:
  - valid handshake → `welcome`; state is stored (FR-020, FR-036)
  - bad signature or unknown device → close 4001
  - no `hello` within 10 s → 4006
  - unknown message type or colliding tool name → 4005; frame over 4 MiB → 1009
  - second connection for the same device → old one closed with 4003 (spec edge case)
  - silence for 35 s → offline, `last_seen_at` kept (FR-012, SC-04)
  - `goodbye` → offline with its reason stored (FR-020)
  - `goodbye` with `user_disconnected` → device revoked, close 4002 (FR-052)
  - device revoked → 4002 and its in-flight calls fail (FR-052)
- **T017** Hub `internal/hub`: device ID → live connection, per-connection call IDs, concurrent
  calls, deadlines (default 10 s, tool `_meta` up to 60 s), `cancel` on deadline, late results
  dropped, no queueing. Behind an interface so a later version can route across servers.
  *Serves D1, D3, FR-011, FR-012, FR-025. Done when T016 passes.*
- **T018** [P] **(test first)** Offline message rendering: every row of the table in
  `mcp-surface.md`, in the Mac's time zone with relative time, labeled UTC as fallback. Fixed
  clock. *Serves FR-010, FR-037.*
- **T019** [P] Implement offline message rendering. *Done when T018 passes.*
- **T020** **(test first)** MCP surface contract tests with the go-sdk client against the relay
  (handler built without the auth layer; auth is added in M2):
  - `initialize` works with 2025-11-25 (stateful) and 2026-07-28 (stateless)
  - never paired: `tools/list` is only `laptop_status`; calling a Mac tool returns the
    "never paired" text
  - offline: `tools/list` = `laptop_status` + last reported tools; `tools/call` returns
    `isError: true` with the offline text, in under 1 s (FR-010, FR-013, SC-03)
  - online: `battery_status` is forwarded and its result returned
  - deadline: timeout text, and the test agent receives `cancel` (FR-011)
  - revoked during a call: "disconnected" text
  - new `tools` from the agent → `notifications/tools/list_changed` to stateful sessions (FR-062)
  - `laptop_status` structured content and text match the contract (FR-021)
- **T021** Implement `internal/mcpserver` with go-sdk `StreamableHTTPHandler`. *Serves D2. Done
  when T020 passes.*
- **T022** [P] Audit log: one metadata row per tool call (tool, surface from `clientInfo.name`,
  outcome, duration; no arguments, no results), daily purge after 30 days. Tests first.
  *Serves D11, FR-022, FR-023, FR-024.*

---

## M2: OAuth, passkeys, pairing (relay side)

- **T030** Store: the remaining tables from `data-model.md` (passkeys, email_tokens,
  web_sessions, pairing_codes, oauth_clients, oauth_codes, oauth_tokens). Tests first.
- **T031** **(test first)** OAuth contract tests against the relay:
  - unauthenticated `/mcp` → exactly `401` with the `WWW-Authenticate` header from the contract
  - protected resource metadata at both paths; `resource` equals the connector URL
  - authorization server metadata has every required field
  - DCR at `/register` (JSON); CIMD with an HTTPS `client_id` (fetched, validated, cached up to
    24 h; served by a local test server)
  - authorization code + PKCE S256 required; plain or missing PKCE rejected
  - redirect URIs: the claude.ai callback; loopback `/callback` on any port; others only if
    registered; anything else rejected
  - `/token` accepts form encoding; refresh rotates and returns a new token; the old one still
    works for 60 s; expired or invalid → `400 invalid_grant`
  - `/revoke` works; a revoked token is rejected on `/mcp`
  - token endpoint p99 under 2 s with no outbound calls (CIMD cached)
  - after 7 days offline (fake clock), refresh still works and `laptop_status` answers (SC-07)
  *Serves D4, FR-014, FR-040.*
- **T032** fosite wiring with SQLite storage, opaque HMAC tokens stored hashed, lifetimes from D4.
- **T033** Client lookup: CIMD fetch and cache, DCR registration, redirect URI matching.
- **T034** Bearer protection on `/mcp` with go-sdk `auth.RequireBearerToken` and
  `auth.ProtectedResourceMetadataHandler`; token → user → device. `/mcp` never redirects.
  *Done when T031 passes.*
- **T035** [P] **(test first)** Passkey and email tests with a software WebAuthn authenticator and
  a fake SMTP server: sign-up requires email verification; passkey sign-in; no password path
  exists; the recovery link is single-use, expires in 15 min, and is announced by email; a
  connected test agent receives `notice` `account_recovered`, and an offline one receives it on
  its next connection. *Serves D5, FR-041, FR-042, FR-043.*
- **T036** Implement `internal/account`: go-webauthn (discoverable, user verification required),
  go-mail SMTP, server-rendered sign-up, sign-in, and recovery pages, and the recovery `notice`.
  *Done when T035 passes.*
- **T037** Consent page at `/authorize` showing the client name and the redirect URI's host.
- **T038** Account page: list and revoke the Mac (close 4002), revoke Claude's access (tokens),
  delete the account (hard delete of all rows), audit log view. Tests first. *Serves FR-044,
  FR-045, FR-052, US7.*
- **T039** **(test first, then implement)** Pairing: `/pair` after passkey sign-in →
  `latchkey://paired?code=...`; single-use 5-minute code exchanged together with the device's
  P-256 public key, creating the device. Tested with the Go test agent end to end. *Serves D6,
  FR-050.*
- **T040** MCP Inspector against the local relay through the full OAuth flow, with the Go test
  agent paired.

---

## M3: Mac app

- **T050** Mac project: `macos/project.yml` (XcodeGen) with targets `Latchkey` (menu bar app,
  `LSUIElement`), `LatchkeyHelper` (daemon, launchd plist in `Contents/Library/LaunchDaemons`),
  and `Shared`. Hardened runtime, not sandboxed. `DEVELOPMENT_TEAM` from gitignored
  `macos/Local.xcconfig` with a committed `Local.xcconfig.example`. Generated `.xcodeproj`
  gitignored. Add build and test commands to CLAUDE.md. *Serves D9, FR-073, FR-075. Done when
  `xcodegen && xcodebuild` produces a signed app containing the helper.*
- **T051** [P] **(test first)** Swift tests: `Shared` agent protocol `Codable` types decode and
  encode every fixture in `contracts/fixtures/` the same way as Go.
- **T052** [P] **(test first)** Keep-awake state machine tests. Inputs: power source, battery %,
  thermal state, user setting, helper available. Output: `on`, `off_user`, `off_low_battery`,
  `off_too_hot`, or `off_helper_unavailable`, plus whether to send `goodbye` and its reason.
  Cover 15% on battery, charger reconnect, serious and critical thermal, and recovery only when
  the user didn't turn it off. *Serves FR-032, FR-033, FR-034.*
- **T053** [P] **(test first)** Backoff and close-code policy tests: 1 s to 30 s with jitter;
  each close code maps to the contract's action. *Serves FR-004, SC-05.*
- **T054** [P] **(test first)** `pmset -g` output parser tests (reading `SleepDisabled` back),
  from captured samples. *Serves FR-031.*
- **T055** Implement protocol types, state machine, reconnect policy, and parser. *Done when T051
  to T054 pass.*
- **T056** Helper daemon and XPC: `Shared/HelperProtocol.swift` (`setSleepDisabled`,
  `readSleepDisabled`); Mach-service listener with `setCodeSigningRequirement` for the app;
  runs `/usr/bin/pmset -a disablesleep 1|0` and reads it back; turns sleep back on when the
  client disconnects, and at startup if no client connects within 60 s. *Serves D7, FR-035.*
- **T057** [P] Power monitor: `IOPSCopyPowerSourcesInfo` and change notifications, thermal state,
  Low Power Mode, lid state (`AppleClamshellState`), IANA time zone → State. *Serves D8, FR-036,
  FR-037.*
- **T058** [P] Device key: P-256 key in the Secure Enclave (CryptoKit), reference in the
  Keychain, signs the challenge. A cross-language test checks that a Swift signature verifies in
  Go. *Serves D6, FR-051.*
- **T059** Pairing in the app: "Connect" opens `ASWebAuthenticationSession` to `/pair`, handles
  `latchkey://paired`, exchanges the code with the device public key; "Disconnect" sends
  `goodbye` `user_disconnected` and deletes the local key; close 4002 shows "Disconnected from
  account". *Serves FR-050, FR-051, FR-052.*
- **T060** Connection: `URLSessionWebSocketTask` with subprotocol `latchkey.v1`; handshake;
  `state` every heartbeat and on change; reconnect on `NWPathMonitor` change and on wake,
  otherwise backoff; close-code policy; `notice` `account_recovered` shown as a macOS
  notification. *Serves D1, FR-002, FR-004, FR-042.*
- **T061** Keep-awake controller: state machine → `IOPMAssertion` and helper over XPC; registers
  the helper with `SMAppService.daemon(plistName:)` and opens Login Items settings when approval
  is needed; sends `goodbye` before turning keep-awake off; re-applies and reads back on every
  power-source change and wake. *Serves D7, D8, FR-030 to FR-035.*
- **T062** Capabilities: registry; "System info" with `battery_status` (5000 ms in `_meta`),
  answering in the contract's output schema; toggling sends the full `tools` list; disabled tools
  are never sent. *Serves FR-060 to FR-063, Constitution III.*
- **T063** Menu bar UI (SwiftUI `MenuBarExtra`): connected or not, battery, keep-awake and why
  it is off, Connect and Disconnect, capability toggles, relay URL setting, start at login
  (`SMAppService.mainApp`), Quit restores sleep. *Serves FR-070, FR-071, FR-081.*
- **T064** Local trace: SQLite in Application Support recording every executed call (arguments,
  results, errors, timings), a log window, 90-day purge. Never sent to the relay. *Serves D11,
  FR-026.*
- **T065** Integration check with a local relay: pair through the browser; a go-sdk client calls
  `battery_status` and gets live data; Wi-Fi off → offline within 35 s (SC-04); Wi-Fi on →
  reachable within 10 s (SC-05); disabling System info removes the tool (SC-08).

---

## M4: End to end from Claude

- **T070** Public test deployment of the relay with HTTPS. [Blocked: hosted relay domain is an
  open question for Toni.]
- **T071** Write `specs/001-core/quickstart.md`: the setup checklist from a fresh Mac and fresh
  Claude account.
- **T072** Run the quickstart: add the connector on claude.ai web; confirm it appears on Desktop,
  iOS, and Android; call `battery_status` from each. Measure SC-01 (time, number of actions) and
  SC-02 (phone round trip p95 under 3 s). *Serves FR-001, US1.*
- **T073** Measure Claude's hosted tool-call timeout; confirm the 60 s cap is below it; record in
  `research.md` and resolve the D3 clarification.
- **T074** Offline checks from real Claude: shutdown, low battery, and timeout give the contract
  texts; the connector never shows as broken (US2, SC-03).

---

## M5: Packaging

- **T080** Relay container: distroless Dockerfile, one volume at `/data`, optional ACME. Test
  that it starts with only the D10 environment variables. *Serves FR-080.*
- **T081** [P] Self-hosting README: run the container, set up SMTP, point the app at a custom URL.
  *Serves US8, FR-081.*
- **T082** Developer ID signing and notarization for the app and helper. [Waiting on Toni's Apple
  Developer ID.] *Serves FR-072, Constitution IV.*
- **T083** Sparkle 2 with EdDSA-signed archives and an appcast. *Serves FR-072.*
- **T084** Uninstall check: deleting the app leaves sleep at the default and no background item
  (SC-09).

---

## Requirement coverage

| Requirement | Tasks |
|---|---|
| FR-001 | T072 |
| FR-002, FR-004 | T053, T060, T065 |
| FR-003 | T070 |
| FR-010 | T018, T019, T020, T074 |
| FR-011 | T017, T020, T074 |
| FR-012 | T016, T017, T065 |
| FR-013 | T020 |
| FR-014 | T031 |
| FR-020, FR-021 | T016, T020 |
| FR-022 to FR-024 | T022 |
| FR-025 | T017 |
| FR-026 | T064 |
| FR-030, FR-031 | T054, T056, T061 |
| FR-032 to FR-034 | T052, T061 |
| FR-035 | T056, T061, T084 |
| FR-036, FR-037 | T018, T057, T060 |
| FR-040 | T031 to T034 |
| FR-041 to FR-043 | T035, T036, T060 |
| FR-044, FR-045 | T038 |
| FR-050 to FR-052 | T016, T039, T058, T059 |
| FR-060 to FR-063 | T020, T062, T065 |
| FR-070, FR-071 | T063 |
| FR-072 | T082, T083 |
| FR-073 | T050, T056 |
| FR-075 | T050 |
| FR-080 | T080 |
| FR-081 | T063, T081 |
| SC-01, SC-02 | T072 |
| SC-03 | T020, T074 |
| SC-04, SC-05 | T016, T065 |
| SC-06 | Normal use (no dedicated test, plan D7) |
| SC-07 | T031 |
| SC-08 | T065 |
| SC-09 | T056, T084 |
