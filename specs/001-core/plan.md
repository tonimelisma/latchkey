# Plan 001: Core — HOW

Derived from `spec.md`. Every decision names the requirement(s) it serves. Evidence is in
`research.md`.

## Architecture

```
Claude (web / Desktop / iOS / Android)          Anthropic's cloud calls the relay; egress 160.79.104.0/21
        │  HTTPS, MCP Streamable HTTP, OAuth 2.1 bearer token
        ▼
┌──────────────────────────── Relay (Go, one binary, SQLite) ────────────────────────────┐
│  /mcp            MCP server: handshake, tools/list (cached), laptop_status, forwarding   │
│  /.well-known/*  OAuth discovery (RFC 9728 protected resource, RFC 8414 auth server)    │
│  /authorize /token /register   OAuth authorization server (fosite)                       │
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
Serves FR-002, FR-004, FR-012; Constitution I.
The relay must exist anyway (stable URL, OAuth, memory), so a third-party tunnel would only add a
second hop and a per-user provisioning step. A closed socket means "offline" instantly.
- Transport: WSS on 443 (passes through home routers, hotel Wi-Fi, and most corporate proxies).
- Liveness: the app sends a `state` message every 15 s; the relay also sends WebSocket pings.
  Offline after 35 s of silence (SC-04 requires 45 s).
- Reconnect: immediately on network path change (`NWPathMonitor`) and on wake
  (`NSWorkspace.didWakeNotification`); otherwise exponential backoff with jitter, 1 s to 30 s cap
  (SC-05).
- Newest connection for a device wins; the old one is closed with code 4003.

### D2. The relay is the MCP server, not a pass-through
Serves FR-010, FR-013, FR-014, FR-021, SC-03, SC-07; Constitution II.
- Library: official `github.com/modelcontextprotocol/go-sdk` (v1.8+), `mcp.StreamableHTTPHandler`.
- Protocol versions: 2025-11-25 (stateful; Claude's hosted runtime still sends `initialize`) and
  2026-07-28 (stateless). The SDK serves 2026-07-28 only from a stateless handler, so `/mcp` runs
  two handlers and routes by the `MCP-Protocol-Version` request header (2026-07-28 or later →
  stateless). Stateful sessions live in memory on the single server.
- One MCP server instance per Owner, created on first use, holding `laptop_status` plus that
  Owner's Mac tools; sessions are bound to the OAuth token's user by the SDK.
- `tools/list` returns `laptop_status` plus the last tool list the Mac reported, even when offline.
- `tools/call` for a Mac tool goes to the hub. Offline: immediate `isError: true` result with the
  offline message (FR-010). Online: forwarded with a deadline (D3).
- Tool-list changes: `notifications/tools/list_changed` to stateful sessions (FR-062). A sync
  takes the Owner's server lock before it reads the stored list, so two syncs apply their lists
  in the order they read them and an older list can't overwrite a newer one (security review,
  2026-10-25).
- Session limits (FR-090; security review, 2026-10-25): the stateful handler runs with the SDK's
  `SessionTimeout` of 30 minutes, counted from the last request of the session; the next request
  of a closed session gets `404` and the client starts a new one, as the MCP transport
  specifies. Before a request that opens a session, the relay closes the Owner's oldest sessions
  beyond 64 (the SDK has no cap of its own; it lists a server's sessions oldest first).
  Options weighed for the cap: refusing the new session (locks the Owner out when a leaked token
  fills the quota) or closing the oldest (chosen: the Owner's newest conversation always works).
  The Owner's server and its sessions are dropped from memory when the account is deleted, when
  Claude's access is removed, and on recovery (`mcpserver.Forget`).

### D3. Deadlines
Serves FR-011, Constitution II.
- Default deadline 10 s per call. A tool may declare a longer one in its metadata, capped at 60 s.
  `battery_status` uses 5 s. The declared number is clamped to 1 ms to 60 s before it becomes a
  duration, so a huge or non-finite value from the Mac can't wrap around to a negative deadline
  (security review, 2026-10-25).
- On deadline: the relay returns a timeout error, sends `cancel` to the Mac, and drops any late
  result.
- [NEEDS CLARIFICATION: Claude's hosted client timeout is undocumented. Measure it in M4 and keep
  our cap below it.]

### D4. OAuth authorization server: fosite plus Claude's client registration methods
Serves FR-040, FR-014.
- `github.com/ory/fosite` (Apache-2.0) for authorization code + PKCE S256, token issuance, refresh
  rotation. Opaque HMAC tokens stored hashed.
- Client registration, implemented in fosite's client storage:
  - CIMD: when `client_id` is an HTTPS URL, fetch and validate the metadata document, cache it
    (respect HTTP caching, max 24 h).
  - DCR (RFC 7591) at `/register` for clients that don't use CIMD.
- Metadata: advertise `client_id_metadata_document_supported: true`,
  `token_endpoint_auth_methods_supported` including `none`, `code_challenge_methods_supported:
  ["S256"]`, `offline_access` in `scopes_supported`.
- Redirect URIs accepted: `https://claude.ai/api/mcp/auth_callback`, plus loopback
  `http://localhost/*` and `http://127.0.0.1/*` with any port (Claude Code).
- Resource side: go-sdk `auth.RequireBearerToken` and `auth.ProtectedResourceMetadataHandler`;
  unauthenticated requests get `401` with `WWW-Authenticate: Bearer resource_metadata=...`.
- Lifetimes: access token 1 h, refresh token 90 days, rotated on every use, with a 60 s grace
  window for the previous token (network retries). SC-07 needs at least 7 days.
- Endpoint latency: discovery, registration, and token endpoints respond well under 10 s (Claude's
  limit); no outbound calls on the token path except a cached CIMD fetch.
- Consent screen shows the client name and the redirect URI's host. The name is the client's own
  claim, so wherever it appears (consent page, account page, the Mac's `client_authorized`
  notice) it is followed by the host the relay checked: the client ID's host for a CIMD client
  (the relay fetched the document there), else the redirect host, as "Claude (claude.ai)"
  (security scan, 2026-10-24). Hosts are shown in ASCII (`golang.org/x/net/idna`, already in
  the module graph, now a direct dependency), so a look-alike Unicode host appears as `xn--...`.
  The name is cleaned before it is shown: control and formatting characters (newlines,
  direction overrides, zero-width marks) and parentheses removed, spaces collapsed, at most 60
  characters, so it can't carry a "(claude.ai)" of its own. The consent page shows the host on
  its own line ("This app is at claude.ai."), not only after the name. The account page names a
  registered client with every host its redirect URIs point to ("Claude (claude.ai,
  other.example)"). Options weighed for that: recording the redirect host with each approval
  (a migration, and one more thing stored); requiring one host per registered client (refuses
  clients that list several hosts today); listing every host, chosen as the only one that is
  never narrower than where the client's codes can go.
- Consent is asked every time (FR-049a; Toni, 2026-10-25, replacing the remembered approval of
  FR-049): a `GET /authorize` only ever renders the consent page, and a code is issued only by
  the `POST` of its Allow button with the session's CSRF token, for every client, loopback ones
  included (RFC 8252 §8.6: a program on the Owner's computer can pose as a native client, so a
  remembered approval would hand it a code unseen). Nothing about an approval is stored: the
  `oauth_consents` table is dropped (migration 6), and the account page lists the clients that
  hold a live (unexpired, unrevoked) access or refresh token, with the time of the oldest one.
  A client that was approved but never redeemed its code is not listed, since it has no access.
  Options weighed for the list: keeping the table as a plain record of approvals (stores more
  than needed, and goes stale when tokens expire or are revoked by the client), or reading the
  tokens, chosen because it is exactly "who can reach the Mac now" and stores nothing new.
- Redirect URIs must be registered by the client (CIMD document or DCR); for loopback URIs
  (`localhost`, `127.0.0.1`, `[::1]`) the port is ignored. fosite ignores the port only for IP
  literals, so the client lookup adds the requested `localhost` URI when it matches a registered
  one on everything but the port.
- Tokens: fosite's HMAC strategy with a 32-byte secret generated on first start and kept in the
  database, so tokens survive restarts (SC-07). Refresh rotation marks the old token rotated; it
  stays valid for 60 s, after which reuse revokes the whole token family (RFC 6819 §5.2.2.3).
- Revoking Claude's access (FR-044) cannot be outrun by a refresh already in flight: it deletes
  the Owner's codes and tokens, and a new access or refresh token is
  written only if a code or refresh token of the same grant and Owner still exists and no token
  of that grant has been revoked (a client's `/revoke` and reuse detection mark tokens revoked
  rather than deleting them), checked in the same SQL statement as the insert. A refresh whose token vanished mid-exchange fails
  (`invalid_request`) instead of minting tokens. Options weighed: fosite's transactional
  storage with `BEGIN IMMEDIATE` (touches every storage call and holds the write lock across
  the client lookup, which may fetch a CIMD document for seconds), or a per-Owner revocation
  generation on every token (a new column and a check on every `/mcp` request); the
  conditional insert closes the gap with neither cost (security scan, 2026-10-24).
- Resource indicator: an `resource` parameter, if sent, must equal the connector URL.

### D5. Owner authentication: passkeys only, email recovery
Serves FR-041, FR-042, FR-043.
- `github.com/go-webauthn/webauthn` (BSD-3), discoverable credentials, user verification required.
- One sign-in page (FR-043a), email first: a verified account with passkeys continues with its
  passkey; a new account gets a 6-digit code by email (15 minutes, 5 wrong attempts, stored hashed
  with the user ID), then creates a passkey. Recovery is the same with a recovery code. The email
  field also offers saved passkeys through WebAuthn conditional mediation (autofill). Codes keep
  the whole journey in one window, so the Mac app's sign-in window never sends the Owner to
  another tab. Sign-up is open unless `ALLOWED_EMAILS` is set (FR-046).
- Web sessions: an HTTP-only, Secure, SameSite=Lax cookie holding a random ID stored hashed;
  30 days (FR-048). Account deletion requires a fresh passkey assertion. Forms carry a CSRF token
  tied to the session. Every JSON endpoint of the sign-in page, including the passkey finish
  steps that start a session, accepts only `Content-Type: application/json`, which a cross-site
  page cannot send without a CORS preflight the relay never answers (no login CSRF).
- After sign-in the page returns only to a path on the relay itself: the `next` value must parse
  with no scheme or host, start with a single `/`, and contain no control character or backslash
  (browsers drop the first and read the second as `/`); otherwise `/account`. The page's script
  checks the same origin again before navigating (security scan, 2026-10-24).
- Wrong codes (FR-042, FR-042a): checking a code, counting a wrong one, and using a right one
  happen in one `BEGIN IMMEDIATE` transaction, so concurrent guesses cannot get past the
  5-attempt limit and a code is used once. Each address also counts wrong codes per day on its
  `users` row (`wrong_codes`, `wrong_codes_since`, migration 5); new codes don't reset it. After
  20 within a day of the first, every emailed code for the address is refused (HTTP 429, "Too
  many wrong codes were entered for this email address today. Sign in with your passkey, or try
  again tomorrow.") and no new code is emailed until 24 hours after that first wrong code;
  passkey sign-in is unaffected. Options weighed: a separate table of wrong-code times (more
  rows, sliding window) or carrying the attempt count over to the next code (still unbounded
  across days); two columns on `users` are the smallest change that bounds a day.
- Recovery: single-use code, 15 min expiry, stored hashed; completing it removes all old passkeys
  (FR-047), signs out every browser, and removes every Claude client's access (its codes and
  tokens), as "Remove Claude's access" does (FR-047a); the recovery page and
  emails say Claude must connect again. Using it is announced by email and in the
  Mac app. The Mac app learns of it through a `notice` message (contracts/agent-protocol.md), sent
  at once if the Mac is online, otherwise on its next connection (the relay compares the
  recovery's `used_at` with the device's last connection; nothing new is stored).
- Email: SMTP via `github.com/wneessen/go-mail`; configured by environment variables (FR-080).
  The hosted relay sends through Resend's SMTP from `no-reply@` its own host name. Mail is always
  encrypted: TLS from the start on port 465, required STARTTLS on other ports (a server that
  doesn't offer it gets nothing, so an on-path attacker can't strip it and read codes); only a
  server on loopback (a local test mail catcher) may be plain (security scan, 2026-10-24).
- Web pages: server-rendered `html/template` with a small script for WebAuthn calls, and one small
  hand-written stylesheet (system font, light and dark) embedded in the binary. No frontend
  framework, no CSS library.

### D6. Pairing: browser sign-in, Secure Enclave device key
Serves FR-050, FR-051, FR-052, FR-053, FR-054; Constitution IV.
- The app opens `ASWebAuthenticationSession` (Apple's sign-in window; it uses the default browser
  when that browser supports it, else Safari, and closes itself on the callback) to `/pair`; the
  Owner signs in on the one email-first page; the relay redirects to
  `latchkey://paired?code=...&relay=...`; the app exchanges the code. The session's completion
  handler runs off the main thread. That callback is trusted and needs no dialog.
- A `latchkey://paired` link that reaches the app any other way (the system's URL handler, from
  another browser, with or without a pairing in progress) is used only after the Owner confirms
  an alert titled with the relay's host, saying which account email that relay claims, whether
  the relay differs from the paired one (or, unpaired, the hosted relay the app suggests), and
  that it replaces the current pairing if there is one (FR-054). The app gets the email from `POST /pair/preview`, which looks the code
  up without using it (contracts/agent-protocol.md "Pairing"); if that fails the alert says the
  link expired and has no Connect button. Confirming cancels a sign-in window that is still open.
  A link carrying the code the sign-in window just delivered is ignored (already used).
- During the exchange the app registers a P-256 public key whose private key lives in the Secure
  Enclave (CryptoKit). No bearer secret leaves the Mac.
- The pairing (relay address, device ID, and the key's Secure Enclave blob) is one generic
  password item in the Owner's login keychain, created by the app, so other programs can't read
  or change it without the Owner's password. User defaults, which any program running as the
  Owner can change without a permission, hold none of it: a relay address there pointed the app
  and its privacy permissions at another relay (security scan, 2026-10-24). Reads look only in
  the login keychain (opened by its path), never prompt, and refuse more than one match; the
  address must still be https (http only for localhost). An older version's pairing (address and
  ID in user defaults, key in its own item) is never used, only removed: the Owner pairs again.
  0.8.4 moved it instead and lost the only one (Toni's) when its stricter read couldn't see the
  old key; a review then found that any retried move leaves a window for planted settings, and
  no other installs exist, so the move was dropped (2026-10-24). Capability levels stay in user
  defaults: they only limit what the paired Claude can use.
- WebSocket authentication: the relay sends a nonce; the app signs it with the device key
  (contracts/agent-protocol.md).
- Pairing while a Mac is paired shows the current Mac's name and asks to replace it (FR-053);
  confirming revokes the current Mac before the new one is created.
- Revocation deletes the device's public key and closes its socket with code 4002. It starts from
  the web account page, or from "Disconnect" in the app, which sends `goodbye` with reason
  `user_disconnected`; the relay treats that reason as a revocation.

### D7. Keep-awake: SMAppService helper daemon
Serves FR-030, FR-031, FR-035, FR-073; Constitution IV.
- Lid open, idle: the app itself holds an `IOPMAssertion` of type
  `PreventUserIdleSystemSleep`. Public API, no privileges.
- Lid closed: only the system `SleepDisabled` setting prevents clamshell sleep. That requires root,
  so a helper daemon registered with `SMAppService.daemon(plistName:)` performs exactly two
  operations: set it on and set it off, by running `/usr/bin/pmset -a disablesleep 1|0` (there is
  no public API for this setting).
- The Owner approves the helper once in System Settings → General → Login Items.
- XPC: Mach service; the helper accepts connections only from our app's code-signing requirement
  (`setCodeSigningRequirement`).
- Re-apply and verify on every power-source change (`IOPSNotificationCreateRunLoopSource`) and wake;
  read back the setting to confirm (FR-031).
- Restore: the app turns it off on quit; the helper turns it off when its client disconnects and on
  its own startup if no client connects within 60 s. That covers crashes and uninstall (FR-035,
  SC-09).
- `disablesleep` is not documented by Apple; its behavior is known from third-party apps
  (research.md), with conflicting reports about power-source changes on Apple silicon. The
  re-apply-and-read-back above is the mitigation. No separate spike or hardware test run
  (Toni, 2026-10-20).

### D8. Power and thermal monitoring
Serves FR-032, FR-033, FR-034, FR-036, FR-063.
- Battery and power source: `IOPSCopyPowerSourcesInfo` and change notifications.
- Thermal: `ProcessInfo.thermalState` and `thermalStateDidChangeNotification`. Serious or critical
  turns keep-awake off.
- Low Power Mode is reported in state but does not by itself turn keep-awake off.
- Turning keep-awake off is reported at once in a `state` message (`keep_awake:
  off_low_battery` or `off_too_hot`); the Mac may stay awake and reachable for a while (lid open,
  in use). When macOS announces sleep (`NSWorkspace.willSleepNotification`), the app sends
  `goodbye` with reason `low_battery` or `too_hot` if keep-awake was off for that reason, else
  `system_sleep`, so the relay can answer "went to sleep for low battery at 14%". Power-off
  (`willPowerOffNotification`) sends `system_shutdown`; quitting sends `user_quit`.

### D9. Mac app packaging
Serves FR-070, FR-071, FR-072; Constitution IV.
- Project: generated by XcodeGen from `macos/project.yml` (text, reviewable, no `.pbxproj` merge
  conflicts). The generated `.xcodeproj` is not committed.
- SwiftUI `MenuBarExtra`; `SMAppService.mainApp` for start at login. The app is an agent
  (`LSUIElement`) and switches its activation policy to `.regular` while a window is open, so it
  shows in the Dock and Cmd-Tab, and back to `.accessory` when the last window closes (FR-079).
- Tests with Swift Testing; formatting with swift-format (ships with Xcode).
- Hardened runtime, Developer ID signing, notarization. Not sandboxed: later capabilities (Full Disk
  Access for Messages, Apple Events, Accessibility) are incompatible with the App Sandbox, and
  changing that later would mean migrating containers. This deviation from "sandboxed where
  possible" is deliberate.
- Updates: Sparkle 2 (pinned 2.10.0) with EdDSA-signed archives. Downloads and the update feed
  (`appcast.xml`) are published on the repository's GitHub Releases by `macos/scripts/release.sh`.
  The updater starts only in builds that carry the public key; the feed needs a public repository.
- Until the Developer ID exists: local builds with Toni's Apple Development certificate (team ID
  in gitignored `macos/Local.xcconfig`). Development signing adds the debugging entitlement
  (`get-task-allow`), which would let any program running as the Owner take over the app and use
  its privacy permissions; Release builds don't inject it (`CODE_SIGN_INJECT_BASE_ENTITLEMENTS =
  NO`), and `package.sh` and `install.sh` refuse an app whose code carries it (security scan,
  2026-10-24). Debug builds keep it for the debugger.
- Bundle identifiers: app `net.melisma.latchkey`, helper `net.melisma.latchkey.helper` (also its
  Mach service name). Swift 6 language mode with strict concurrency.
- The helper's launchd plist sets `RunAtLoad`. Every helper start (at boot or on demand) first
  restores normal sleep; the app turns keep-awake back on when it connects, and re-applies when
  its XPC connection is interrupted. `SleepDisabled` is kernel runtime state (research.md), so a
  setting from a crash or power loss cannot outlive a restart, even if the app was deleted.
- Verification reads `SleepDisabled` from `IOPMrootDomain` (public, unprivileged IORegistry read).
- Install: a disk image with the app and an Applications link (`macos/scripts/package.sh`). On
  first launch outside an Applications folder the app offers to move itself there (FR-078), then
  registers the login item and the helper and opens a setup window for the two steps only the
  Owner can do.
- Uninstall: deleting the app removes the helper's launchd plist and the login item with it,
  because `SMAppService` keeps both inside the bundle. A running app also watches its bundle; when
  it lands in the Trash it disconnects (goodbye `user_disconnected`), restores sleep, unregisters
  both items, deletes the Keychain keys (device and activity log), settings, activity log, caches, and saved state, and quits
  (FR-077). If the app was quit before being deleted, its small settings file and activity log
  remain, as with most Mac apps; sleep and background items are clean either way. Replacing the
  app with a newer copy is not an uninstall: the trashed copy waits up to 5 s for a Latchkey to
  reappear at its old path (read from that path's `Info.plist`; `Bundle(path:)` caches), then
  opens it and quits. The move-to-Applications step quits a running older copy and deletes it
  rather than trashing it.
- Minimum macOS: current and previous major release, Apple silicon only (FR-075). If a required
  API needs a newer release, the floor moves up and this line says why.

### D10. Relay implementation
Serves FR-080, Constitution V, VIII.
- Go, standard library `net/http`.
- WebSocket: `github.com/coder/websocket`.
- SQLite: `modernc.org/sqlite` (pure Go, so the binary stays static with no cgo). Schema
  migrations with `github.com/pressly/goose/v3` (MIT), SQL files embedded in the binary.
- Tests: standard `testing` with `github.com/stretchr/testify` (MIT). Lint and format:
  golangci-lint with gofumpt, run through `relay/Makefile`.
- TLS: optional built-in ACME (`golang.org/x/crypto/acme/autocert`) so a self-hoster needs no
  reverse proxy; or plain HTTP behind one.
- Container: distroless image, one volume at `/data`, published to
  `ghcr.io/tonimelisma/latchkey-relay`.
- Config (environment): `PUBLIC_URL`, `DATA_DIR`, `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`,
  `SMTP_PASSWORD`, `SMTP_FROM`, `ACME_EMAIL` (optional), `PORT` (optional, default 8080),
  `ALLOWED_EMAILS` (optional, comma-separated; empty means open sign-up, FR-046),
  `TRUSTED_PROXIES` (optional, comma-separated IP addresses and CIDR ranges of reverse proxies
  whose `X-Forwarded-For` the relay believes, besides a proxy on loopback; empty means loopback
  only; FR-082). Abuse limits key on the rightmost `X-Forwarded-For` entry from such a peer and on
  the peer's own address otherwise. The hosted deploy sets it to the subnets of the docker network
  Caddy shares with the relay (research.md).
- Listening: one port, `PORT`, on all network interfaces, IPv4 and IPv6 (research.md). Plain HTTP
  behind a proxy; with `ACME_EMAIL` set, HTTPS on the same port, and the self-hoster maps public
  port 443 to it (Let's Encrypt checks port 443). Certificates and the ACME account key are cached
  in `DATA_DIR/certs`, so restarts reuse them instead of hitting Let's Encrypt's rate limits.
- HTTPS is always required in production (Claude only connects over HTTPS). Typical deployments:
  a hosting platform that terminates HTTPS itself (relay serves plain HTTP on `PORT`); a reverse
  proxy such as Caddy in front; the built-in ACME above; or a tunnel such as Cloudflare Tunnel
  for a home server. Plain HTTP without any of these is accepted only on localhost.
- Hosted instance: on Toni's existing Google Cloud VM (an e2-micro) behind its Caddy, deployed by
  `deploy/deploy.sh`; the address and server details are only in the gitignored `.env`. Sign-up
  is limited to Toni (`ALLOWED_EMAILS`) until the terms and abuse handling exist.
- Scaling: one server. The hub interface is written so a later version can route across servers;
  nothing more is built now.

### D11. Audit log and local trace
Serves FR-022, FR-023, FR-024, FR-026, FR-026a, Constitution VI.
- Relay: one row per tool call, metadata only (no arguments, no results); daily purge after 30 days.
  "Surface" (FR-022) is the MCP `clientInfo.name` from the session's `initialize`, when sent,
  without control or formatting characters and cut to 64 characters (FR-022a).
- Mac app: full trace (arguments, results, errors, timings) in a local SQLite file in the app's
  Application Support folder (SwiftData, `activity.store`), shown in a log window from the menu bar. Never sent to the relay.
  Purged after 90 days by default.
- Each entry is stored as its time (for the purge) plus one AES-256-GCM sealed box (CryptoKit)
  holding tool, arguments, result, outcome, and duration (FR-026a). The key is 256 random bits,
  made on first use and kept as a generic password in the login Keychain (this Mac only,
  readable after first unlock); its access list trusts only the app that created it, so another
  program asking for it makes macOS ask the Owner. Entries are decrypted only to show them; one
  whose key is gone shows as unreadable. The plaintext log of earlier versions (`trace.store`) is
  encrypted into the new file once at start, then its files are deleted. Uninstall (FR-077)
  deletes the key too. Tests use an in-memory key, never the Keychain.

## Repository layout

```
latchkey/
  memory/constitution.md
  specs/001-core/...
  relay/                      Go module
    cmd/relay/main.go
    internal/hub/             live device connections, deadlines, offline answers
    internal/agentproto/      message types for contracts/agent-protocol.md
    internal/mcpserver/       MCP surface, laptop_status, forwarding
    internal/oauth/           fosite wiring, CIMD, DCR, metadata
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
  - Agent protocol: a Go test agent that speaks `contracts/agent-protocol.md`, including bad
    signatures, missed heartbeats, late results, and replaced connections.
  - MCP surface: go-sdk client against the relay; offline, timeout, and list-changed cases.
  - OAuth: full authorization code + PKCE flow with CIMD and with DCR; refresh rotation; bad
    redirect URIs; `401` discovery headers.
- Shared fixtures: one JSON example per agent protocol message in `contracts/fixtures/`, read by
  both the Go and the Swift tests so the two sides cannot drift.
- Mac app: unit tests for the keep-awake state machine (inputs: power source, battery %,
  thermal state, user setting; output: on/off plus reason).
- Browser sign-in: an automated test drives headless Chrome with a virtual passkey through the
  real sign-up, sign-in, consent, and pairing pages, using `github.com/chromedp/chromedp` (MIT).
  Runs in any container with Chrome.
- Claude Code check, run by Claude, not Toni: Claude Code in non-interactive mode (`claude -p` with
  an MCP config carrying an access token obtained by the automated browser sign-in) against a
  local relay plus the paired Go test agent, asking for the battery.
- Real Claude on web, Desktop, and phone through a public test deployment (quickstart checklist).
  Hosting decided at M4.
- No manual testing by Toni; he is asked only for steps that need his accounts or devices.
- No hardware test runs for keep-awake (Toni, 2026-10-20); SC-06 is checked in normal use.

## Milestones

Pairing comes before the Mac app, so the app connects the real way from its first build (Toni,
2026-10-20).

| # | Milestone | Proves |
|---|---|---|
| M1 | Relay hub + agent protocol with Go test agent | D1, D3, FR-010 to FR-013 |
| M2 | OAuth + passkeys + pairing (relay side) | D4, D5, D6 |
| M3 | Mac app: pairs, connects, keeps awake, answers `battery_status` | D6, D7, D8, D9 |
| M4 | End to end from Claude on phone, web, Desktop | FR-001, SC-02, SC-03, SC-07 |
| M5 | Packaging: signing, notarization, Sparkle, Docker image | FR-072, FR-080 |

## Constitution check

| Article | Status |
|---|---|
| I. Outbound only | Pass (D1) |
| II. Fail fast | Pass (D2, D3); hosted Claude timeout to be measured |
| III. Disabled means nonexistent | Pass (FR-061) |
| IV. Good macOS citizen | Pass with one documented exception: no App Sandbox (D9) |
| V. Self-hostable | Pass (D10) |
| VI. Store the minimum | Pass (D11, data-model.md) |
| VII. Test-first | Planned (testing strategy) |
| VIII. Simplicity | Pass: relay, Mac app, specs |
| IX. Open source | Pass: Apache-2.0; all dependencies MIT, BSD, or Apache |
