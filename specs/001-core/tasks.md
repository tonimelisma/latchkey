# Tasks 001: Core

Derived from `plan.md` and `contracts/`. Ordered by milestone; within a milestone, top to bottom.
`[P]` = can run in parallel with the other `[P]` tasks of the same group (different files, no
dependency). Every task names the requirements or decisions it serves and says when it is done.

Test-first (Constitution VII): a task marked **(test first)** writes tests that must be run and
seen failing before the implementation task after it starts.

Shared contract fixtures live in `specs/001-core/contracts/fixtures/` (one JSON file per agent
protocol message). Both the Go and the Swift tests read them, so the two implementations cannot
drift apart.

---

## M0: Keep-awake spike (gate for everything else)

Goal: prove D7 on Toni's MacBook before any other code. Throwaway UI, but the helper and XPC code
are kept.

- **T001** Mac project skeleton. `macos/project.yml` (XcodeGen) with targets `Latchkey` (menu bar
  app, `LSUIElement`), `LatchkeyHelper` (command-line daemon, embedded in the app bundle with its
  launchd plist in `Contents/Library/LaunchDaemons`), and `Shared`. Hardened runtime on, not
  sandboxed. `DEVELOPMENT_TEAM` comes from gitignored `macos/Local.xcconfig`; add a committed
  `Local.xcconfig.example`. Gitignore the generated `.xcodeproj`. Add build commands to CLAUDE.md.
  *Serves D9, FR-073. Done when `xcodegen && xcodebuild` produces a signed app containing the
  helper.*
- **T002** `Shared/HelperProtocol.swift`: XPC protocol with `setSleepDisabled(_:reply:)` and
  `readSleepDisabled(reply:)`. *Serves D7.*
- **T003** [P] **(test first)** Unit tests for parsing `pmset -g` output into the `SleepDisabled`
  value, using captured output samples. *Serves FR-031.*
- **T004** Helper daemon: Mach-service XPC listener with `setCodeSigningRequirement` for the app's
  identity; runs `/usr/bin/pmset -a disablesleep 1|0` and reads it back. Turns sleep back on
  when the client disconnects, and at startup if no client connects within 60 s. *Serves D7,
  FR-035. Done when T003 passes and a client with a different signature is rejected.*
- **T005** Spike app: registers the helper with `SMAppService.daemon(plistName:)`, handles
  `requiresApproval` by opening Login Items settings, holds an `IOPMAssertion`
  (`PreventUserIdleSystemSleep`), and re-applies and verifies `SleepDisabled` on every power-source
  change (`IOPSNotificationCreateRunLoopSource`) and on wake. Writes a timestamped heartbeat line
  every 30 s to a log file so gaps show sleep. *Serves D7, FR-030, FR-031.*
- **T006** Hardware run on Toni's Mac: lid closed on battery for at least 2 hours, with 3 charger
  plug and unplug cycles. Check the heartbeat log and `pmset -g log` for any sleep. Also check:
  (a) does the daemon run under the Apple Development signature (open question in plan D9)?
  (b) quit, `kill -9`, and deleting the app each restore sleep (FR-035, SC-09)? Record the results
  in `research.md`.
  *Done when results are recorded. **Gate:** if lid-closed keep-awake fails, stop and revisit D7
  with Toni before M1.*

---

## M1: Relay hub and agent protocol, Go test agent

- **T010** Go module `relay/` (`github.com/tonimelisma/latchkey/relay`), `cmd/relay/main.go`
  reading the D10 environment config, and the package directories from the plan's layout. Add
  `go test ./...` and run commands to CLAUDE.md. *Serves D10.*
- **T011** Contract fixtures: write `contracts/fixtures/*.json` for every message in
  `agent-protocol.md` (challenge, hello, welcome, state, tools, progress, result, goodbye, call,
  cancel), plus invalid examples (unknown type, tool named `laptop_status`). *Serves Constitution
  VII.*
- **T012** [P] **(test first)** `internal/agentproto` tests: every fixture round-trips; unknown
  fields are ignored; unknown types and colliding tool names are rejected; `deadline_ms` is capped
  at 60000; signature input is built exactly as the contract says.
- **T013** [P] **(test first)** `internal/store` tests for the M1 tables: `devices`,
  `device_state`, `audit_log` (see `data-model.md`).
- **T014** Implement `internal/agentproto` and `internal/store` (SQLite, `modernc.org/sqlite`,
  schema migrations). *Done when T012 and T013 pass.*
- **T015** Go test agent `internal/testagent`: dials `/agent/v1`, signs the challenge with a P-256
  key, sends tools and state, answers calls through pluggable handlers (with delay, error, never
  answer, late answer), and can send bad signatures, skip heartbeats, and send oversize frames.
- **T016** **(test first)** Agent protocol contract tests using the test agent against an
  `httptest` relay. The clock and timeouts must be injectable so tests are fast:
  - valid handshake → `welcome`; state is stored (FR-020, FR-036)
  - bad signature or unknown device → close 4001
  - no `hello` within 10 s → 4006
  - unknown message type or colliding tool name → 4005; frame over 4 MiB → 1009
  - second connection for the same device → old one closed with 4003 (edge case)
  - silence for 35 s → offline, with `last_seen_at` kept (FR-012, SC-04)
  - `goodbye` → offline with its reason stored (FR-020)
  - device revoked → 4002 and its in-flight calls fail (FR-052)
- **T017** Hub `internal/hub`: map from device ID to live connection, per-connection call IDs,
  concurrent calls, deadlines (default 10 s, tool `_meta` up to 60 s), `cancel` on deadline, late
  results dropped, no queueing. Keep it behind an interface so a later version can route across
  servers. *Serves D1, D3, FR-011, FR-012, FR-025. Done when T016 passes.*
- **T018** [P] **(test first)** Offline message rendering: each row of the table in
  `mcp-surface.md`, rendered in the Mac's time zone with relative time and labeled UTC as a
  fallback. Uses a fixed clock. *Serves FR-010, FR-037.*
- **T019** [P] Implement offline message rendering. *Done when T018 passes.*
- **T020** **(test first)** MCP surface contract tests with the go-sdk client against the relay,
  OAuth not yet wired in (handler built without the auth layer in tests):
  - `initialize` works with 2025-11-25 (stateful) and 2026-07-28 (stateless)
  - never paired: `tools/list` is only `laptop_status`; calling a Mac tool returns the
    "never paired" text
  - offline: `tools/list` = `laptop_status` + last reported tools; `tools/call` returns
    `isError: true` with the offline text, in under 1 s (FR-010, FR-013, SC-03)
  - online: `battery_status` is forwarded and its result returned
  - deadline: timeout text, and the test agent receives `cancel` (FR-011)
  - revoked during a call: "disconnected" text
  - new `tools` from the agent → `notifications/tools/list_changed` to stateful sessions (FR-062)
  - `laptop_status` structured content and text both match the contract (FR-021)
- **T021** Implement `internal/mcpserver` with go-sdk `StreamableHTTPHandler`. *Serves D2. Done
  when T020 passes.*
- **T022** [P] Audit log: one metadata row per tool call (tool, surface if known, outcome,
  duration; no arguments, no results), plus a daily purge of rows older than 30 days. Tests
  first. *Serves FR-022, FR-023, FR-024.*

---

## M2: Mac app connects and answers `battery_status`

- **T030** [P] **(test first)** Swift tests: `Shared` agent protocol `Codable` types decode and
  encode every fixture in `contracts/fixtures/` with the same results as Go.
- **T031** [P] **(test first)** Keep-awake state machine tests. Inputs: power source, battery %,
  thermal state, user setting, helper available. Output: `on`, `off_user`, `off_low_battery`,
  `off_too_hot`, or `off_helper_unavailable`, plus whether to send `goodbye` and its reason.
  Cover: 15% on battery, charger reconnect, serious and critical thermal, recovery only when the
  user didn't turn it off. *Serves FR-032, FR-033, FR-034.*
- **T032** [P] **(test first)** Backoff and close-code policy tests: 1 s to 30 s with jitter;
  each close code in the contract maps to the right action. *Serves FR-004, SC-05.*
- **T033** Implement the protocol types, state machine, and reconnect policy. *Done when T030 to
  T032 pass.*
- **T034** [P] Power monitor: `IOPSCopyPowerSourcesInfo` plus change notifications, thermal state,
  Low Power Mode, lid state (`AppleClamshellState` in the IORegistry), and IANA time zone → State.
  *Serves D8, FR-036, FR-037.*
- **T035** [P] Device key: P-256 key in the Secure Enclave (CryptoKit), reference kept in the
  Keychain, signs the challenge. A cross-language test checks that the Go verifier accepts a
  signature made by the Swift code. *Serves D6, FR-051.*
- **T036** Connection: `URLSessionWebSocketTask` with subprotocol `latchkey.v1`; handshake;
  `state` every heartbeat and on change; reconnect on `NWPathMonitor` change and on wake, otherwise
  backoff; follows the close-code policy. *Serves D1, FR-002, FR-004.*
- **T037** Capabilities: registry of capabilities and their tools; "System info" with
  `battery_status` (deadline 5000 ms in `_meta`), answering in the contract's output schema;
  turning a capability on or off sends a full `tools` list. A disabled capability's tools are
  never sent. *Serves FR-060, FR-061, FR-062, FR-063, Constitution III.*
- **T038** Keep-awake controller: connects the state machine to the `IOPMAssertion` and the helper
  over XPC; sends `goodbye` before turning keep-awake off; re-applies on power change and wake.
  *Serves D7, D8, FR-030 to FR-035.*
- **T039** Menu bar UI (SwiftUI `MenuBarExtra`): connected or not, battery, keep-awake and the
  reason it is off, capability toggles, relay URL setting, start at login (`SMAppService.mainApp`),
  Quit restores sleep. *Serves FR-070, FR-071, FR-081.*
- **T040** Local trace: SQLite in Application Support recording every executed call (arguments,
  results, errors, timings), a log window, and a 90-day purge. Never sent to the relay.
  *Serves D11, FR-026.*
- **T041** Temporary device registration until M3 pairing: a `relay` subcommand that adds a
  device public key for a test user. *Done when the app can connect to a local relay.*
- **T042** M2 check on the real Mac with a local relay: a go-sdk client calls `battery_status` and
  gets live data; Wi-Fi off → offline within 35 s (SC-04); Wi-Fi on → reachable within 10 s
  (SC-05); disabling System info removes the tool (SC-08). Record results.

---

## M3: OAuth, passkeys, pairing

- **T050** Store: the remaining tables from `data-model.md` (users, passkeys, email_tokens,
  web_sessions, pairing_codes, oauth_clients, oauth_codes, oauth_tokens). Tests first.
- **T051** **(test first)** OAuth contract tests against the relay:
  - unauthenticated `/mcp` → exactly `401` with the `WWW-Authenticate` header from the contract
  - protected resource metadata at both paths; `resource` equals the connector URL
  - authorization server metadata has every required field
  - DCR at `/register` (JSON); CIMD with an HTTPS `client_id` (fetched, validated, cached up to
    24 h; served by a local test server)
  - authorization code + PKCE S256 required; a plain challenge or missing PKCE is rejected
  - redirect URIs: the claude.ai callback; loopback `/callback` on any port; others only if
    registered; anything else rejected
  - `/token` accepts form encoding; refresh rotates and returns a new token; the old one still
    works for 60 s; expired or invalid → `400 invalid_grant`
  - `/revoke` works; a revoked token is rejected on `/mcp`
  - token endpoint p99 under 2 s with no outbound calls (CIMD cached)
  - an access token works on `/mcp` after 7 days with refresh (SC-07, fake clock)
  *Serves D4, FR-040, FR-014.*
- **T052** fosite wiring with SQLite storage, opaque HMAC tokens stored hashed, lifetimes from D4.
- **T053** Client lookup: CIMD fetch and cache, DCR registration, redirect URI matching rules.
- **T054** Bearer protection on `/mcp` with go-sdk `auth.RequireBearerToken` and
  `auth.ProtectedResourceMetadataHandler`; the token maps to the user and then the device. Never
  redirect `/mcp`. *Done when T051 passes.*
- **T055** [P] **(test first)** Passkey and email tests with a software WebAuthn authenticator and
  a fake SMTP server: sign-up needs email verification; passkey sign-in; no password path exists;
  recovery link is single-use, expires in 15 min, and is announced by email. *Serves FR-041,
  FR-042, FR-043.*
- **T056** Implement `internal/account`: go-webauthn (discoverable, user verification required),
  go-mail SMTP, server-rendered pages for sign-up, sign-in, recovery. *Done when T055 passes.*
- **T057** Consent page at `/authorize` showing the client name and redirect host.
- **T058** Account page: list and revoke the Mac (4002), revoke Claude's access (tokens), delete
  account (hard delete of all rows), audit log view. Tests first. *Serves FR-044, FR-045,
  FR-052, US7.*
- **T059** **(test first)** Pairing: `/pair` after passkey sign-in → `latchkey://paired?code=...`;
  single-use 5-minute code exchanged for registering the device public key. Remove the temporary
  T041 command, or keep it for self-hosters (decide then). *Serves D6, FR-050.*
- **T060** Mac app pairing: "Connect" opens `ASWebAuthenticationSession`, handles the URL scheme,
  exchanges the code; "Disconnect" revokes and deletes the local key; close 4002 shows
  "Disconnected from account". *Serves FR-050, FR-051, FR-052.*
- **T061** Recovery announced in the Mac app. [NEEDS CLARIFICATION: the agent protocol has no
  relay → agent notice message. Needs a contract change (for example a `notice` message) before
  this task.] *Serves FR-042, spec edge case.*
- **T062** MCP Inspector against the local relay, through the full OAuth flow.

---

## M4: End to end from Claude

- **T070** Public test deployment of the relay with HTTPS. [Blocked: hosted relay domain is an
  open question for Toni.]
- **T071** Write `specs/001-core/quickstart.md`: the setup checklist from a fresh Mac and fresh
  Claude account.
- **T072** Run the quickstart: add the connector on claude.ai web; confirm it appears on Desktop,
  iOS, and Android; call `battery_status` from each. Measure SC-01 (time and number of actions)
  and SC-02 (phone round trip p95 under 3 s). *Serves FR-001, US1.*
- **T073** Measure Claude's hosted tool-call timeout and confirm the 60 s cap is below it; record
  the result in `research.md` and resolve the D3 clarification.
- **T074** Offline checks from real Claude: shut down, low battery, and timeout cases give the
  contract texts; the connector never shows as broken (US2, SC-03). Start the 7-day offline test
  (SC-07).
- **T075** Full SC-06 hardware run with the real app: 8 hours lid closed on battery, 3 charger
  cycles, until the 15% threshold; then confirm the low-battery `goodbye` reaches Claude through
  `laptop_status`.

---

## M5: Packaging

- **T080** Relay container: distroless Dockerfile, one volume at `/data`, optional ACME. Test
  that the image starts with only the D10 environment variables. *Serves FR-080.*
- **T081** [P] Self-hosting README: run the container, set up SMTP, point the app at a custom URL
  (US8, FR-081).
- **T082** Developer ID signing and notarization for the app and helper. [Waiting on Toni's Apple
  Developer ID.] *Serves FR-072, Constitution IV.*
- **T083** Sparkle 2 with EdDSA-signed archives and an appcast. *Serves FR-072.*
- **T084** Uninstall check on a clean Mac: deleting the app leaves sleep at the default and no
  background item (SC-09).
- **T085** License file. [NEEDS CLARIFICATION: MIT or Apache-2.0, Toni to pick (Constitution IX).]

---

## Requirement coverage

| Requirement | Tasks |
|---|---|
| FR-001 | T072 |
| FR-002, FR-004 | T032, T036, T042 |
| FR-003 | T070 |
| FR-010 | T018, T019, T020, T074 |
| FR-011 | T017, T020, T074 |
| FR-012 | T016, T017, T042 |
| FR-013 | T020 |
| FR-014 | T051 |
| FR-020, FR-021 | T016, T020 |
| FR-022 to FR-024 | T022 |
| FR-025 | T017 |
| FR-026 | T040 |
| FR-030, FR-031 | T004, T005, T006, T038, T075 |
| FR-032 to FR-034 | T031, T038, T075 |
| FR-035 | T004, T006, T038, T084 |
| FR-036, FR-037 | T018, T034, T036 |
| FR-040 | T051 to T054 |
| FR-041 to FR-043 | T055, T056, T061 |
| FR-044, FR-045 | T058 |
| FR-050 to FR-052 | T016, T035, T059, T060 |
| FR-060 to FR-063 | T020, T037, T042 |
| FR-070, FR-071 | T039 |
| FR-072 | T082, T083 |
| FR-073 | T001, T004 |
| FR-075 | T001 |
| FR-080 | T080 |
| FR-081 | T039, T081 |
| SC-01, SC-02 | T072 |
| SC-03 | T020, T074 |
| SC-04, SC-05 | T016, T042 |
| SC-06 | T006, T075 |
| SC-07 | T051, T074 |
| SC-08 | T042 |
| SC-09 | T006, T084 |
