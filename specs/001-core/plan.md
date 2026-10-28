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
Serves FR-002, FR-004, FR-012; Constitution I.
The relay must exist anyway (stable URL, OAuth, memory), so a third-party tunnel would only add a
second hop and a per-user provisioning step. A closed socket means "offline" instantly.
- Transport: WSS on 443 (passes through home routers, hotel Wi-Fi, and most corporate proxies).
- Liveness: the app sends a `state` message every 15 s; the relay also sends WebSocket pings.
  Offline after 35 s of silence (SC-04 requires 45 s).
- What the app sends stays far inside the relay's limits on a Mac's connection (FR-036a): a
  `state` on change goes out at most once a second (the first change at once, the latest state
  when the second is over; a state equal to the last one sent, apart from the time it was read,
  is not sent), plus one per heartbeat; a `tools` list per level change the Owner makes (15
  tools, about 15 KiB; a test keeps it under 64 KiB); one `result` per call the relay sent.
- Reconnect: immediately on network path change (`NWPathMonitor`) and on wake
  (`NSWorkspace.didWakeNotification`); otherwise exponential backoff with jitter, 1 s to 30 s cap
  (SC-05).
- Newest connection for a device wins; the old one is closed with code 4003.
- What a connected Mac can cost the relay is bounded (FR-091, FR-092; security review,
  2026-10-25). Each connection has a token bucket (`golang.org/x/time/rate`, already used for the
  HTTP limits): 60 frames at once, one back every 200 ms; a `result` or `progress` for a pending call is free,
  because `/mcp`'s per-Owner limit already bounds the calls and the app may answer all running
  calls at once; over the allowance the connection is
  closed with 4005. Tool lists are capped at 256 tools and 512 KiB, the byte cap checked on the
  raw JSON before any tool is built. The hello's signature is verified from a small decode of
  `device_id` and `signature` before the full decode, which builds and trial-registers the tool
  list. The stored `tools_json` is written only when the list differs from the stored one
  (`PutDeviceStatus` updates the other columns); a repeated list is not stored and not announced.
- Store writes and the hub lock: the "offline" write at the end of a connection used to run
  inside the hub's one lock, which every `Online` and `Call` takes. It now runs outside it, under
  one of 64 per-device persist locks (picked by a hash of the device ID). A connection writes
  only while it is the device's registered connection, checked under that lock, and the ending
  connection unregisters and writes under it, so the store never ends up showing an older
  connection's state. Options weighed: a lock per device in a map (grows with every device ever
  seen) or a version column checked in SQL (a schema change); the fixed set needs neither.
- A device revoked between its signature check and its registration (when the revocation finds
  no connection to close) is caught by reading the device again right after registering; the
  connection is closed with 4002 (FR-052a).
- Frames to the Mac are written with the request's cancellation removed and a 5 s timeout
  (FR-093): `coder/websocket` closes the whole connection when a write's context ends, so a
  cancelled Claude request, or the OAuth request that triggers a `client_authorized` notice,
  could otherwise disconnect the Mac.

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
- A level turned off or down stops running work on the Mac (FR-066): after sending the new tool
  list, the app looks at each running call; one whose tool is no longer in the list is cancelled
  (its task, and with it the AppleScript, Spotlight, or other program it waits on) and answered
  at once with an ordinary `result` with `is_error` and the reason ("The Mac's owner turned Files
  off in the Latchkey app while this was running, so it was stopped. It may not have finished.").
  The call's own late result is dropped, and the activity log records what Claude was told.
  Calls whose tool is still listed are not touched, so raising a level stops nothing. No new
  protocol message: the relay sees a normal answer. Shell's jobs: spec 004 FR-310.
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

### D4. OAuth authorization server: zitadel/oidc plus Claude's client registration methods
Serves FR-040, FR-014, FR-180 to FR-185.
- `github.com/zitadel/oidc/v3` (Apache-2.0, OpenID-certified; its `op` package) since
  2026-10-27, replacing `github.com/ory/fosite` (Toni, 2026-10-27; research.md, "Replacing
  fosite"). Why: fosite 0.49 depends on `go-jose/v3`, whose JWK/JWS parsing has a high-rated
  CPU denial of service (GHSA-mgcc-cww5-fp2q) with no fixed v3 release, and fosite parsed any
  `client_assertion` sent to `/token` before checking the client, so it was reachable; `make
  security` refused every deploy. `go-jose/v4` is required at 4.1.6 or later (fixed).
  How it is wired (`internal/oauth`):
  - `/token`: zitadel parses the request (form-encoded only) and checks it:
    `ParseAccessTokenRequest` + `ValidateAccessTokenRequest` (code, PKCE S256 verifier, client
    authentication, redirect URI) and `ParseRefreshTokenRequest` + `ValidateRefreshTokenRequest`
    (client, scopes); `CreateAccessToken` asks the storage for the tokens and decides on a
    refresh token (`offline_access` granted). The JSON response is put together by the relay
    rather than by zitadel's `Exchange` handler, which always adds an OpenID Connect ID token
    (and would need a signing key); the relay offers OAuth only. A verifier that isn't 43 to 128
    unreserved characters is refused (RFC 7636 §4.1), as before.
  - `/revoke`: zitadel's `Revoke` handler (client authentication, RFC 7009); the storage revokes
    the token's whole grant, refuses a token of another client (`unauthorized_client`), and
    answers 200 for an unknown or already revoked one.
  - `/authorize` stays the relay's own handler (sign-in, consent asked every time, CSRF), using
    zitadel's `ParseAuthorizeRequest` and `ValidateAuthReqRedirectURI`; the rest of the checks
    are the relay's, in the order and with the answers it always gave: client lookup first
    (FR-183), an untrusted client or redirect URI shown in the browser as JSON (401
    `invalid_client`, else 400) and redirected nowhere, then `unsupported_response_type`,
    `invalid_state` (state shorter than 8 characters), `invalid_scope` (anything but `mcp`
    and `offline_access`), PKCE required with S256 only (`invalid_request`), the resource
    indicator; these are redirected with `error`, `error_description`, `state`, `iss`. zitadel's
    own login-redirect flow (`Authorize`, `AuthorizeCallback`) isn't used: the consent page is
    the login UI, and the code is stored when the Owner presses Allow. A request without
    `redirect_uri` is refused (zitadel requires it; fosite filled in a client's only registered
    URI; every Claude app sends it).
  - Client assertions (`client_assertion`, `client_assertion_type`; `private_key_jwt`,
    `client_secret_jwt`) are refused with `401 invalid_client` at `/token` and `/revoke` before
    zitadel sees the request, so nothing parses them; zitadel's `AuthMethodPrivateKeyJWT` is off
    as well. Request objects (`request`) are ignored, as before.
  - Storage (`op.Storage`) is an adapter on the same `oauth_requests` table (no migration):
    `AuthRequestByCode` (a used code presented again revokes its grant), `TokenRequestByRefreshToken`
    (reuse detection), `CreateAccessToken` / `CreateAccessAndRefreshTokens` (use the code up,
    or rotate the refresh token, then write the tokens with the conditional insert below),
    `GetRefreshTokenInfo` / `RevokeToken`, `GetClientByClientID` (the CIMD/DCR lookup below),
    `AuthorizeClientIDSecret` (SHA-256 of the secret). The OpenID Connect parts (ID tokens,
    userinfo, keys, introspection, end-session) answer "not offered".
  - Fail closed (security review, 2026-10-27): zitadel checks PKCE only when the stored code
    has a challenge, so the storage refuses a code with no S256 challenge in its own form or in
    the `pkce` row fosite wrote beside it (`invalid_grant`), and the code exchange refuses one
    again; and the bearer check on `/mcp` looks the token's client up as every other read does,
    so a token of a client the list now refuses, whose registration is gone, or whose metadata
    document can't be used is refused (FR-180, FR-095), as fosite's storage did.
  - Opaque tokens: zitadel makes a bearer token by "encrypting" a token ID; the relay's
    `op.WithCrypto` returns the ID unchanged, and the ID is the token itself, in the format
    below. The bearer check on `/mcp` is the relay's (the token's HMAC, its row, revoked,
    expiry, the account), not zitadel's.
  - Existing grants carry over: the token format, the key, and the rows are what fosite wrote
    (fosite's prefixed HMAC-SHA512/256, `ory_at_` / `ory_rt_` / `ory_ac_`), and new rows are
    written with the `session_json` shape fosite read, so a rollback to the fosite version also
    still works with them. Tested against a fixture written by the fosite version
    (`internal/oauth/testdata/fosite-0.49-grant.json`): its access token works, its refresh
    token refreshes, its rotated refresh token and its used code still end the grant.
  - What changed that a client could notice: `token_type` stays `bearer`; error descriptions
    are worded differently (codes and status are the same); no PKCE row is written any more
    (the challenge is in the code's row; kind `pkce` stays in the table for old rows).
- Client registration, implemented in the client lookup the storage adapter uses:
  - CIMD: when `client_id` is an HTTPS URL, fetch and validate the metadata document, cache it
    (respect HTTP caching, at least 5 minutes, at most 24 h). Hardening (FR-095; security
    review, 2026-10-25): the minimum exists because the client is looked up on every token and
    `/mcp` request, so a `no-store` document meant a fetch each time, and its host's outage cut
    every user of that client off. When a fetch fails, the last good copy serves for up to 7
    days past its freshness, and the URL is not fetched again for 5 minutes (failures are kept
    in memory by the URL's SHA-256, at most 4,096 of them), so the relay can't be made to
    hammer a host. The fetch runs detached from the request (5 s limit), so a caller that
    leaves can't plant a failure. Cached documents that no code or token refers to are capped
    at the newest 1,000 (checked at each insert) and purged daily once fetched more than a day
    ago; documents of clients holding a grant always stay. `oauth_requests` gets an index on
    `client_id` for those checks (migration 7). A failed lookup's error carries one fixed
    sentence; the reason (which can name internal hosts and addresses) goes to the relay's log
    only. The fixed sentence makes that independent of the OAuth library: every error the
    relay hands zitadel is an `oidc.Error` with a fixed description, and anything else reaches the client as a bare `server_error`.
  - DCR (RFC 7591) at `/register` for clients that don't use CIMD.
  - Which clients are accepted (FR-180 to FR-185; Toni, 2026-10-25: "Claude only" out of the
    box). `ALLOWED_CLIENT_HOSTS` is a comma-separated list of host names, default `claude.ai`;
    the single value `*` means any host. Claude's hosted apps identify themselves with
    `https://claude.ai/oauth/mcp-oauth-client-metadata` and Claude Code with
    `https://claude.ai/oauth/claude-code-client-metadata` (both fetched and read 2026-10-24),
    so the default covers every Claude app. With a list:
    - a CIMD client is looked up only if its client ID's host is on the list (lowercased, IDNA
      ASCII form, exact match, port ignored). The check is the first thing the client lookup
      does, before the cache and before any fetch, so the relay makes no outbound request to a
      host the operator didn't name (FR-183; this also narrows the SSRF surface to the listed
      hosts);
    - every redirect URI in its document must be on a listed host or on a loopback host;
      checked on each lookup, so documents cached before the list changed are covered (FR-181);
    - DCR is off: `/register` answers `403` with `{"error":"access_denied",
      "error_description":"This relay only accepts Claude's apps. ..."}`, the metadata has no
      `registration_endpoint` and lists only `none` under
      `token_endpoint_auth_methods_supported` (there are no clients with a secret), and stored
      `dcr` clients are refused. `client_id_metadata_document_supported: true` and `none` stay,
      which is what makes Claude choose CIMD (FR-182);
    - a refused client gets `invalid_client` with the sentence "This relay only accepts
      Claude's apps." (with a non-default list: "This relay only accepts apps from <hosts>.").
      At `/authorize` that error is shown in the browser and redirects nowhere, because no
      redirect URI was accepted (FR-183). zitadel wraps a failed client lookup at `/token` in
      an `invalid_client` of its own; the lookup's error carries a marker and the handler puts
      the sentence back;
    - at start (`oauth.New`) and in the daily purge, every stored client the list refuses is
      deleted with its codes and tokens in one transaction (`store.DeleteClientsExcept`),
      including tokens whose client row is already gone (FR-184);
    - a value that isn't a list of host names fails `loadConfig`, so the relay doesn't start
      (FR-185).
    The zero value of the setting inside the code is the default list, so a caller that forgets
    it gets "Claude only", never "anyone". Tests and the local checks (`internal/e2e`,
    `cmd/localcheck`, `cmd/maccheck`), which register a throwaway client, set `*`.
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
  direction overrides, zero-width marks) and every bracket (Unicode categories Ps and Pe:
  ASCII, fullwidth, small, ornamental and all other opening and closing punctuation, FR-098)
  removed, spaces collapsed, at most 60
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
  (`localhost`, `127.0.0.1`, `[::1]`) the port is ignored: the client lookup adds the requested loopback URI when it matches a
  registered one on everything but the port (same host, path and query; zitadel then checks for
  an exact match, as a web client). zitadel's own native-app rule was not used: it also lets
  `localhost` stand in for `127.0.0.1` and the reverse.
- Codes are redeemed once, also under concurrency (FR-096; security review, 2026-10-25): the library
  reads a code's row and marks it used in separate steps, so two exchanges could both read it
  unused. The marking is now `UPDATE … WHERE used_at IS NULL`; the exchange that changes no row
  fails (`invalid_grant`), and the grant's rows are all marked
  revoked, which revokes tokens already written and (through the conditional insert below)
  refuses any written later, exactly as for a later replay. A replay found on read marks the
  grant the same way. The token endpoint answers these with `invalid_grant`, never `server_error`. One order still
  slipped through until 2026-10-25 under fosite, which checked PKCE between
  reading the code and marking it, and deletes the PKCE row on first use, so a second exchange
  that had read the code unused found no PKCE row and stopped with `invalid_grant` before the
  marking, leaving the first exchange's tokens alive. The PKCE row is now kept until it
  expires with its code (one minute; the purge removes it), so every exchange of a code
  reaches the marking. Weighed: revoking the grant when the PKCE row is missing but the code
  row exists (an inference from a missing row, and a second place that decides "used twice"),
  or keeping the row (chosen: the decision stays in the one conditional update; the row
  guarded nothing, since fosite checked the code's used mark before it looked at PKCE). Since
  zitadel (2026-10-27) there is no PKCE row: the challenge is read from the code's row, the code
  is read in `AuthRequestByCode` and marked used in `CreateAccessToken` after zitadel's checks,
  so a wrong verifier doesn't use a code up. Options weighed: a transaction around the whole
  exchange (transactional storage; holds SQLite's write lock across the client lookup) or the
  conditional update, chosen as one statement with no lock held.
- RFC 9207 (FR-097): the metadata advertises `authorization_response_iss_parameter_supported`
  and every redirect back to the client (code or error) carries `iss=<issuer>`. The relay
  writes these redirects itself (`redirectBack`), with `iss`. Errors shown in the browser (unknown client or redirect
  URI) aren't redirects and carry none.
- Tokens: opaque HMAC tokens (`internal/oauth/tokens.go`, the format fosite's HMAC strategy
  used, kept so earlier tokens work) with a 32-byte secret generated on first start and kept in the
  database, so tokens survive restarts (SC-07). Refresh rotation marks the old token rotated; it
  stays valid for 60 s, after which reuse revokes the whole token family (RFC 6819 §5.2.2.3).
- Revoking Claude's access (FR-044) cannot be outrun by a refresh already in flight: it deletes
  the Owner's codes and tokens, and a new access or refresh token is
  written only if a code or refresh token of the same grant and Owner still exists and no token
  of that grant has been revoked (a client's `/revoke` and reuse detection mark tokens revoked
  rather than deleting them), checked in the same SQL statement as the insert. A refresh whose token vanished mid-exchange fails
  (`invalid_request`) instead of minting tokens. Options weighed: transactional
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
- Sign-ins in progress (security review, 2026-10-25). A passkey exchange (5 minutes) and the
  ticket a confirmed code gives (10 minutes) live in memory between two requests. Each table is
  capped at 10,000 entries (FR-099): a further one gets HTTP 503 with `Retry-After: 60` and "Too
  many sign-ins are in progress right now. Try again in a minute." Expired entries are swept at
  most once a minute, and whenever a table is full, instead of on every insert. A ticket is
  taken in the same step that checks it, when the passkey registration finishes, so two
  registrations started from one ticket can't both complete; it is put back if that attempt
  fails before a passkey is saved, so the Owner can retry without a new code. When a
  registration completes, every other ticket and pending registration of the account is
  dropped (FR-047b), so a ticket from an earlier recovery code can't add a passkey afterwards
  and, by completing a second recovery, remove the Owner's new one. Options weighed for the
  cap: evicting the oldest entry when full (lets a flood cancel real sign-ins in progress) or
  refusing new ones (chosen: a flood only delays new sign-ins for up to five minutes).
- Recovery requests answer before the email is sent (FR-042b): for a known account the code is
  stored and mailed in a background task (at most 16 at once, 30 s each, failures logged), so
  the answer takes the same time as for an unknown address, where nothing is sent. Before, the
  request waited on the mail server only when the account existed. A send that fails can't be
  reported to the page without revealing the account; the page already tells the Owner to ask
  again if no email arrives.
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
- One such link is handled at a time: while one is being looked up, shown, or exchanged, others
  are dropped (and noted in the log), so links can't stack dialogs or make the app send a burst
  of lookups (FR-054a). A link naming `http://localhost` or `http://127.0.0.1` is accepted only
  in Debug builds; in the installed (Release) app it counts as incomplete, so a link can't make
  the app talk to whatever listens on a local port. The relay field in setup still takes them
  (FR-054b, FR-081).
- The app's log (`log show`) carries relay addresses only as private data (a hash), never in
  the clear.
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
  (`setCodeSigningRequirement`): the app's identifier, Apple's anchor, and the team the helper
  itself is signed with. In Release builds the requirement also refuses a caller that carries
  the debugging entitlement (`get-task-allow`), since any program running as the Owner can take
  over such a process; a Debug app and its Debug helper, which both carry it, accept each other,
  and the installed helper refuses a Debug app. The app checks the helper the same way. A build
  signed without a team has no requirement to check: the helper accepts nobody and the app
  doesn't connect at all (keep-awake then shows as needing the helper), rather than connecting
  unchecked (security review, 2026-10-25).
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
- Updates: Sparkle 2 (pinned to the commit of tag 2.10.0 in `project.yml`, not to the tag, which
  could be moved; the version is in the comment beside it, where
  `scripts/sparkle-advisories.sh` reads it) with EdDSA-signed archives. Downloads and the update feed
  (`appcast.xml`) are published on the repository's GitHub Releases by `macos/scripts/release.sh`.
  The updater starts only in builds that carry the public key; the feed needs a public repository.
- Until the Developer ID exists: local builds with Toni's Apple Development certificate (team ID
  in gitignored `macos/Local.xcconfig`). Development signing adds the debugging entitlement
  (`get-task-allow`), which would let any program running as the Owner take over the app and use
  its privacy permissions; Release builds don't inject it (`CODE_SIGN_INJECT_BASE_ENTITLEMENTS =
  NO`), and `package.sh` and `install.sh` refuse an app whose code carries it (security scan,
  2026-10-24). Debug builds keep it for the debugger.
- `install.sh` checks that an update kept the pairing (2026-10-25; on 2026-10-24 it reported
  success for an app that started "not paired"). Before quitting the old app it notes whether this
  Mac is paired: from the running app's own start line in the log (found by the process's start
  time), or, without one, from whether the pairing record exists in the Keychain (attributes
  only, no secret read). If it was paired and the new app's start line says "not paired", the
  install exits non-zero and says which versions, whether the record is still there, and not to
  pair again yet. The decision is in `install-lib.sh`, tested by
  `scripts/tests/install_pairing_test.sh` without installing anything.
- Bundle identifiers: app `net.melisma.latchkey`, helper `net.melisma.latchkey.helper` (also its
  Mach service name). Swift 6 language mode with strict concurrency.
- Debug and test builds have their own identity (FR-074; Toni, 2026-10-25), because macOS files
  settings, Keychain access, privacy permissions, background items, and link handlers under the
  bundle identifier. While a test copy was also `net.melisma.latchkey`, a test erased the Owner's
  pairing twice, and a leftover Debug build (which carries the debugging entitlement) could
  borrow the installed app's permissions.

  | | Release (installed) | Debug and tests |
  |---|---|---|
  | App identifier, settings domain, Keychain service, log subsystem | `net.melisma.latchkey` | `net.melisma.latchkey.dev` |
  | Helper identifier, launchd label, Mach service | `net.melisma.latchkey.helper` | `net.melisma.latchkey.dev.helper` |
  | Helper's launchd plist in the app | `net.melisma.latchkey.helper.plist` | `net.melisma.latchkey.dev.helper.plist` |
  | Link scheme registered with macOS | `latchkey` | `latchkey-dev` |
  | Data folder in Application Support | `Latchkey` | `Latchkey Dev` |
  | Name shown by macOS (permission lists) | Latchkey | Latchkey Dev |

  The Release column is exactly what shipped up to 0.8.8 and must never change: the installed
  app's pairing, activity-log key, settings, and permissions are filed under it. One mechanism,
  no duplicated files: `project.yml` sets `LATCHKEY_APP_ID`, `LATCHKEY_URL_SCHEME`, and
  `LATCHKEY_DISPLAY_NAME` per configuration; both `Info.plist` files take them by substitution,
  and a build step makes the helper's launchd plist from the one template
  (`Helper/LaunchDaemon.plist`). The code takes every name from `Shared/AppIdentity.swift`
  (chosen at compile time by the Debug flag, so nothing on disk can change which identity a
  build claims), including the code-signing requirements of D7: a Debug app and helper name
  each other's `.dev` identifiers, so the installed helper refuses a Debug app on its identifier
  as well as on its debugging entitlement. The relay's sign-in redirect stays
  `latchkey://paired` for every build: the sign-in window catches it inside the app, which
  needs no registration; a Debug build reads system-delivered links under `latchkey-dev` too.
  Files' own-files refusal (spec 003 FR-210) covers the running build's settings and data and
  the installed app's. Tests still use stand-ins for all stored data. A Debug app run by hand
  needs its own pairing, permissions, and helper approval.
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
Serves FR-080, FR-186 to FR-189, Constitution V, VI, VIII.
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
  `ALLOWED_CLIENT_HOSTS` (optional, default `claude.ai`; D4), `KEY_FILE` (optional, default
  `DATA_DIR/relay.key`; below),
  `TRUSTED_PROXIES` (optional, comma-separated IP addresses and CIDR ranges of reverse proxies
  whose `X-Forwarded-For` the relay believes, besides a proxy on loopback; empty means loopback
  only; FR-082). Abuse limits key on the rightmost `X-Forwarded-For` entry from such a peer and on
  the peer's own address otherwise. The hosted deploy sets it to the subnets of the docker network
  Caddy shares with the relay (research.md).
- Slow requests (FR-094; security review, 2026-10-25): headers must arrive within 10 s
  (`ReadHeaderTimeout`). A request with a body gets a read deadline when it arrives (30 s; 2
  minutes on `/mcp`, whose bodies may be 16 MiB), set per request with
  `http.ResponseController` and cleared the moment the body has been read to its end. Options
  weighed: the server-wide `ReadTimeout` (stays armed after the body and cancels the request when
  it fires, which would end tool calls and MCP event streams, and it can't differ per route), or
  a deadline per request that ends with the body (chosen). Requests without a body (event
  streams, the Mac's WebSocket upgrade) get none.
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
- The relay's own keys (FR-186 to FR-189; Toni, 2026-10-25; Constitution VI). `relay_keys`
  holds the OAuth token HMAC key and the CSRF key. Each value is sealed with AES-256-GCM under
  a 32-byte key read from `KEY_FILE` (default `DATA_DIR/relay.key`), with a fresh random
  12-byte nonce per value and the row's name as additional authenticated data (a value can't be
  moved to another row). The row's `format` column is the version: 0 is the unencrypted form of
  earlier versions, 1 is nonce followed by ciphertext and tag (migration 8). All of it happens
  in `store.Open`, before anything reads a key:
  - no key file and no sealed rows: the file is created (`O_EXCL`, mode 0600, synced; the
    folder must exist), and the relay logs the path;
  - the file must be a regular file of exactly 32 bytes with no group or other permission
    bits, or the relay refuses to start;
  - every sealed row must open, or the relay refuses to start with a message that names the
    two ways out; nothing is deleted or regenerated by itself;
  - rows with format 0 are converted in one `BEGIN IMMEDIATE` transaction with
    `secure_delete` on: seal, write, read back, open, compare with the old value, and roll
    everything back on any mismatch; then the database is vacuumed and the write-ahead log
    truncated so the old bytes don't linger in free pages. The keys' values don't change, so
    tokens issued before still verify (FR-188).
  - `relay reset-keys --confirm` (the relay stopped) deletes the stored keys, every OAuth code
    and token, and every web session, in one transaction, and touches nothing else (FR-189).
  Hosted deployment: the key file lives outside the data volume, in
  `/opt/latchkey/keys/relay` on the VM (the folder above it is root-only, mode 0700; the inner
  one belongs to the container's user, uid 65532, mode 0700), mounted at `/keys`, with
  `KEY_FILE=/keys/relay.key` set in the compose file. A copy of the database or of the data
  volume alone is then useless for forging tokens. Rollback across the conversion: a version
  from before can't read sealed rows, so the first deploy of this version (recognised by the
  key file not existing on the VM) stops the relay, copies the database files to a root-only
  folder, and starts the new version; if that version doesn't come up, the rollback puts the
  copy back, removes the new key file, and starts the previous version. Once the new version
  answers, the copy (which holds the keys unencrypted) is deleted; from then on going back to
  a version before this one means `reset-keys` semantics by hand (everyone signs in again).
- Scaling: one server. The hub interface is written so a later version can route across servers;
  nothing more is built now.

### D11. Audit log and local trace
Serves FR-022, FR-023, FR-024, FR-026, FR-026a, FR-610 to FR-615, Constitution VI.
- Relay: one row per tool call, metadata only (no arguments, no results), with its call id; kept
  until the account is deleted, nothing deleted by age (D18; until 2026-10-27, a daily purge after
  30 days).
  "Surface" (FR-022) is the MCP `clientInfo.name` from the session's `initialize`, when sent,
  without control or formatting characters and cut to 64 characters (FR-022a).
- Mac app: full trace (arguments, results, errors, timings) in a local SQLite file in the app's
  Application Support folder (SwiftData, `activity.store`), shown in a log window from the menu bar. Never sent to the relay.
  Kept until uninstall: nothing is deleted by age (FR-026, Toni 2026-10-26; the 90-day purge
  of earlier versions is gone). The window's footnote gives the store's size on disk, SQLite's
  side files included (FR-610). Disconnect, revocation, and pairing again touch only the
  pairing's Keychain items (`pairing`, `device-key`, `pairing-migrated`), never the log, its
  key, or its record (FR-611).
- Each entry is stored as its time (for sorting and the date filter) plus one AES-256-GCM sealed box (CryptoKit)
  holding tool, arguments, result, outcome, and duration (FR-026a). The key is 256 random bits,
  made on first use and kept as a generic password in the login Keychain (this Mac only,
  readable after first unlock); its access list trusts only the app that created it, so another
  program asking for it makes macOS ask the Owner. Entries are decrypted only to show them; one
  whose key is gone is left out of the menu and the window's table, and the window says how many
  such entries there are (FR-203; counted by a query on the entry's key ID, without decrypting). The plaintext log of earlier versions (`trace.store`) is
  encrypted into the new file once at start, then its files are deleted. Uninstall (FR-077)
  deletes the key too. Tests use an in-memory key, never the Keychain.
- Tamper check (FR-612, research.md "Tamper-evident activity log"): each entry recorded from this change on
  has a number `seq` (1, 2, … across keys), a key ID (8 bytes HKDF-derived from the log key, as
  hex), and `mac` = HMAC-SHA256, under a second HKDF-derived key, over the previous entry's mac
  (32 zero bytes for the first), seq, the entry's ID, its stored time, and the key ID. Its sealed
  box binds seq and ID as authenticated data, so content can't be swapped between rows. The
  check walks the entries under the current key in seq order, reading only the clear fields,
  and lists each entry whose mac doesn't follow (resyncing on its stored mac, so later breaks
  are found too); a sealed box under the current key that no longer opens counts as changed.
  The window runs it off the main thread each time it opens. Entries from before (seq 0) are
  shown with "Before check". The upgrade is SwiftData's in-place migration (the new fields have
  defaults), then one pass that gives every old entry the ID of the key that opens it (or "-")
  in a single save; a failed save changes nothing and is retried at the next start.
- Newest-entry record (FR-613): Keychain item `activity-log-latest` (57 bytes: version, key ID,
  seq, mac), added when there is none and then replaced with `SecItemUpdate` (no moment without
  it) after each save, never before. At start: no record → fine, or "missing" when checked
  entries exist (said in one line; the next entry adds one); a record that can't be read or isn't
  understood → left alone and not written for the launch, one line said, no alarm; a record of
  another key → replaced as entries come. The chain continues from the newer of the record and
  the log, so an end cut off stays visible as a break at the next entry. The check warns
  "newer entries are missing" when the record's entry is gone with nothing after it, naming the
  newest entry still there; the wording also allows for a power cut losing the last write.
- Browsing (FR-614): pages of 200, newest first, continued from the last shown entry (time, seq)
  with a time-range query the `(at, seq)` index serves; the date filter is part of that query.
  Text and tool are matched after decrypting, in batches of 1,000, on every core, on a
  `ModelContext` of its own off the main thread; nothing searchable is stored in the clear.
  Export… (FR-615) writes the same query oldest first, a page at a time, as JSON Lines to the
  file chosen in `NSSavePanel`. Timings for 100,000 entries are in research.md.
- The Keychain look (`Keychain.lookup`) answers one of three things: no item (only when the
  search itself says "not found"), the item's data, or "there is an item that can't be read"
  (every other failure: a Keychain error, more than one match, no data). A new log key is made
  only on "no item", and saved with a write that refuses to replace; on "can't be read", or a key
  that isn't 32 bytes, the log is unavailable for the launch (`ActivityLog.unavailable` with the
  sentence shown in the Activity window; the menu says "Activity Log Unavailable"), the reason is
  logged at error level, and nothing is written (FR-201). The pairing record is read with the
  same look; no code path at start writes or deletes it, and the start line in the log says
  "pairing record present but unreadable" instead of "missing pairing record" (FR-202).

### D12. Apps with access: one row per approval, pushed to the Mac
Serves FR-190, FR-191, FR-192; Constitution II, VI.
- A grant is one Allow on the consent page: its request ID, shared by the code and every
  token that descends from it (refresh keeps the ID). The relay stores one `oauth_grants` row
  per grant when the Owner allows it, before the code leaves: a public ID (16 random bytes,
  `grt_…`), and what the consent page showed (cleaned name, checked host, the redirect host or
  "this computer" for loopback). A grant is live while it has an unrevoked, unexpired access or
  refresh token; the list is the live grants, newest first, at most 50. Grants from before the
  table (migration 10 gives each a row) have no stored name: theirs is read from the client.
- Agent protocol: `hello.features`, `clients`, `revoke_client` (contracts/agent-protocol.md).
  The hub asks a callback for the Owner's list and sends it after `welcome` and whenever the
  OAuth server reports a change, only on connections that announced `clients`. A per-connection
  lock covers reading the list and writing it, so lists arrive in order; a list equal to the
  last one sent (ignoring last-used times) is skipped. `revoke_client` runs the same removal as
  the account page, is counted by the frame allowance (FR-091), and is audited as metadata.
- What reports a change: the token endpoint when a code is redeemed (the grant's first token);
  `RevokeGrant` (Mac, account page) and `RevokeUser` (remove all, recovery); the storage adapter's
  calls for a client's `/revoke`, refresh-token reuse, and a replayed code, when the grant is no
  longer live afterwards; and the daily purge, which re-sends to every connected Mac.
- Removing one grant deletes its rows in one transaction, so no token can be written for it
  afterwards (`PutOAuthToken` needs a live row of the grant). The MCP layer closes that grant's
  sessions only: the bearer check puts the grant's public ID into the token info, `/mcp`
  records it for each session it opens, and `ForgetGrant` closes the sessions recorded for it.
  Requests with the removed token already fail the bearer check.
- Last used: the bearer check notes the time per grant in memory and writes `last_used_at` only
  when a minute has passed since the last write for that grant.
- Account page: each app has its own Remove button (CSRF-protected POST); "Remove Claude's
  access" still removes all.
- Mac app (0.8.10): `hello` asks for the list with `features: ["clients"]`. The menu lists the
  Claude apps with access while the Mac is connected to a relay that sends the list, and shows
  nothing about them for a relay that doesn't (FR-190). Every list is checked as the contract
  says (a malformed one is a protocol violation) and replaces the one shown (FR-192). Remove
  Access… asks first, because it can't be undone from the Mac; it then sends one
  `revoke_client` and takes the entry out of the menu. If no list without the entry arrives
  within 5 seconds, or the connection drops, the entry is put back and the Owner is told
  (FR-191). Every removal is written to the Mac's activity log. The relay's names are never
  empty ("An unnamed app" stands in) and its IDs look like `grt_…`; the app treats both as
  opaque text.
- With the default list of allowed client hosts (D4, FR-180) every entry is one of Claude's
  apps: host `claude.ai`, sent back to `claude.ai` (web, Desktop, phone) or "this computer"
  (Claude Code). Clients the list no longer allows lose their tokens at start and in the daily
  purge (FR-184); the purge then re-sends the list to connected Macs.

### D13. Terms and privacy policy, from the operator's settings
Serves FR-193, FR-194; Constitution V, VI.
- Settings `OPERATOR_NAME` and `OPERATOR_CONTACT` (both or neither; the contact must be one
  plain email address), and optional `OPERATOR_LAW`, `OPERATOR_PROVIDERS`, `BACKUP_DAYS`. With
  the two set, `/terms` and `/privacy` are served from `html/template` files, with the pages'
  style and headers and no script; the footer of every page links them; the email step of the
  sign-in page says "By continuing, you agree to the Terms and the Privacy Policy"; and the
  authorization-server metadata carries `op_tos_uri` and `op_policy_uri`. Without them the two
  paths are 404 and nothing links to them.
- The texts describe "this relay" and say only what the code does. Each shows its effective
  date, a constant beside the template that changes with the text. A test renders the policy
  and requires a phrase for every table in `data-model.md` and in the database, so the policy
  can't fall behind what is stored; another fails on any address, name, or place written into
  the templates.

### D14. Operator commands in the relay binary; the running relay follows the database
Serves FR-195 to FR-199; Constitution II, V.
- The image has no shell, so the commands are subcommands of the one binary
  (`/relay account …`, `/relay block …`), run with `docker exec`; `relay` with no arguments
  still starts the server. They open the same SQLite file (WAL, 5 s busy timeout), need only
  `DATA_DIR`, print one line, and exit 1 on failure. Emails are normalized as at sign-up.
- A suspension is one transaction: mark the user, delete their web sessions, emailed codes,
  OAuth codes, tokens, and grants, and write the operator log. Nothing else is deleted.
- Everything the relay checks per request reads the database, so it takes effect at once:
  the session lookup joins the user and ignores a suspended one; the bearer check refuses a
  suspended user; the sign-in steps refuse a suspended account or a blocked address with a
  plain message (with the contact address when set); the Mac's handshake answers 4001.
- What is held in memory (the Mac's open connection, Claude's open sessions) is reached through
  the operator log: the relay reads entries newer than the last one it handled every 2 seconds
  and closes the Mac's connection (4001 for a suspension or block, so the app keeps its
  pairing; 4002 for a deletion, as the Delete account button does) and drops the account's MCP
  sessions. Worst case 2 s plus the query. A connection that registers just after its account
  was suspended is caught by re-reading the user after registering, as for revocation.
- The Mac app comes back by itself after a suspension (FR-204): it reads the close reason
  (`URLSessionWebSocketTask.closeReason`), and on 4001 "account suspended" shows "This account
  is suspended on the relay" with a second line ("Contact the relay’s operator. Latchkey
  reconnects by itself when the suspension ends."), keeps the pairing, and waits 5 minutes
  instead of stopping; the wait ends early on wake or a network change, as its normal reconnect
  wait does. `ReconnectPolicy.next(afterClose:reason:attempt:)` is that decision as a pure
  function (what to show, when to retry). `make mac-check` suspends the account under the real
  connection code, checks what it shows, and lifts the suspension.
- The operator log is purged after a year by the daily job.
- The commands open the database exactly as the server does, key file included (D10, FR-186):
  `DATA_DIR` and `KEY_FILE` from the container's environment. With the key file missing or
  wrong, a command refuses as the server would, changes nothing, and never makes a key file of
  its own beside sealed keys. `reset-keys` (FR-189) is a command of its own, for a stopped relay.

### D15. Menu bar: state in the icon's shape, a short menu, a Settings window, Pause
Serves FR-070, FR-076, FR-190, FR-600 to FR-605, spec 002 FR-131 and FR-132; Constitution II,
III, IV. Guidance checked against Apple's Human Interface Guidelines (research.md, "Menu bar
design", 2026-10-26).
- Icon: SF Symbols `key.fill` (reachable) and `key.slash` (not reachable; Apple's slash variant
  for "unavailable"), with at most one small mark beside the key: `pause.fill`, `exclamationmark`,
  or the existing dot. A pure function of (connection status, paused, setup unfinished, calls
  running) picks it, so a unit test covers every case. Template images only, no color.
- Menu, top to bottom: status line (and the suspension advice, the keep-awake problem, or the
  last error when there is one); Keep Mac Awake, Pause/Resume Claude's Access; Recent Activity
  (the newest five, then Show All Activity…); Settings… (⌘,), Check for
  Updates… when available; Quit Latchkey (⌘Q). The battery line is gone.
- Activity titles: "time  Capability: target", the capability from the tool's prefix and the
  target from the first of `command`, `path`, `url`, `query`, `to`, `title`, `app`, `action` in
  the arguments, on one line, at most 40 characters; without one, the tool's own title.
- Settings window: SwiftUI's `Settings` scene with a tab per pane (What Claude Can Do,
  Permissions, Claude Apps, Connection, General), which gives the toolbar, the pane title, ⌘, and reopening the last
  pane. Opened from the menu with `openSettings`, then the app is activated (a menu bar app's
  window would otherwise open behind others). The Claude Apps pane shows the whole list, so the separate "Show All Apps…" window is gone.
- Permissions pane (FR-606): a pure function turns what the app's checks found (the same ones
  setup uses) and the levels into one row per permission: allowed, missing (the levels need it;
  exactly what makes setup unfinished), not needed, or optional (Contacts after "Don't Allow").
  Its buttons call the setup steps' actions; while the pane is open it re-checks every second,
  as the setup window does. Setup stays the first-run walk-through and opens itself only when
  something is missing.
- Pause is the Mac's own state, stored in user defaults so it survives restarts (FR-604). The
  relay doesn't change: the tools stay listed, as they do while the Mac is offline, and every
  call is answered at once with the pause error (FR-602), so nothing waits (II). Capability
  levels are untouched, so III holds. Pausing stops running calls through the same path as a
  lowered level (FR-066) and stops every shell job (FR-603). Refused calls are logged in the
  activity like any other.
- Disconnect This Mac asks first with an alert: "Disconnect" (destructive style, Return doesn't
  press it) and "Cancel", as Remove Access… already does (FR-605).

### D18. Relay audit trail
Serves FR-022, FR-024, FR-630 to FR-637; Constitution II (the comparison never waits on the
Mac: the relay answers from its own database) and VI (metadata only, fixed words, no
addresses, bounded for strangers).
- Nothing is deleted by age: the 30-day purge of `audit_log` is gone, and the daily
  housekeeping (`Relay.Daily`) touches neither the audit nor `events`. Deleting the account
  deletes both (foreign keys with cascade). A test runs the housekeeping 1, 5, and 30 years
  ahead and finds every row.
- Call ids (FR-632): `agentproto.NewCallID`, `call_` and 16 bytes from `crypto/rand` in
  Crockford base32 (26 characters, upper case). The MCP layer makes the id before it looks at
  the Mac, so a call answered "offline" or "never paired" has one too, sends it in `call`, and
  stores it in `audit_log.call_id` (migration 12; old rows `''`). The audit write no longer
  shares the request's cancellation, so a call whose client went away is audited as well.
- The Claude app's name in each call (FR-637): the surface the audit stores (the session's
  `clientInfo.name`, cleaned as FR-022a says) is computed once per call and sent as `call.client`,
  left out when unknown, so the Mac's log and the relay's audit name the app the same way.
- Audit comparison (FR-634, contract "Audit comparison"): a connection whose hello listed
  `audit` may send `audit_request`; the relay answers from `AuditForDevice` (this Mac's rows,
  `at >= since`, oldest first, at most the limit cut to 1000) with `next_since`. A page never
  ends inside a millisecond whose rows go on: those rows start the next page. An invalid
  `since` or `limit` gets an empty page and `null`. `audit_request` from a connection without
  the feature closes it with 4005, and `audit` is never sent unasked, so apps before the
  feature never see the message. The request counts against the frame allowance (FR-091).
- Event record (FR-631): table `events` (migration 12, data-model.md) written through
  `internal/events.Recorder`, which stores each event and logs one `slog` line with the event's
  kind, account, Mac, and detail. Recorded by the hub (connected with versions, keep-awake, and
  features; disconnected with close code, reason, and goodbye reason; keep-awake changes from
  hello, `state`, and `goodbye`, only on change; refused handshakes; Disconnect in the app),
  the account pages (each sign-in step and outcome by passkey, emailed code, and recovery;
  pairing; unpairing on the account page, by a new pairing, and with the account), and the
  OAuth server (approved, refused on the consent page, removed on the account page, from the
  Mac app, by a recovery, by the client's own revocation or token reuse, and by expiry in the
  daily purge, which now returns the approvals it ended). Every refused or failed HTTP request
  (status 400 and up) is recorded by the outermost handler with its route pattern (never the
  path the client sent), status, and a reason the handler noted (`events.Note`: "no token",
  "token rejected: …", "rate limit per address", "request too large", …) or the status's
  meaning.
- Strangers can't grow the record (research.md "The relay's event record"): refusals, refused
  handshakes, and sign-in steps anyone can cause are counted, one row per hour, kind, account,
  and detail, and only the first of each hour is logged. Details are fixed words, so the rows
  without an account grow by at most one per kind and reason an hour.
- Output (FR-635): the MCP SDK's server gets the relay's logger filtered to warnings and errors,
  so its "server connecting", "session connected", and "session disconnected" lines per request
  are gone and its warnings stay. The relay's output is the event lines, warnings, and errors.
- Not recorded as events: the operator's commands (they have `operator_log`, FR-195, and run in
  another process), and the account's deletion, which is only logged (its record goes with it).

### D17. Unsettled states, and the installer's checks of the running app
Serves FR-621, FR-622. Each setup step is a `SetupStep` (done, missing, unknown);
`SetupDecision` counts only `missing`. Location's state comes from `LocationFixer`'s
`locationManagerDidChangeAuthorization` (kept in `LocationFixer.known`), never from a fresh
manager, so it is `unknown` until Core Location's first callback. At start a paired Mac polls
every 250 ms, up to 5 s, until no step is unknown, then logs "Setup is finished" or "Opening
setup: missing …" (`permissions` category). `install.sh` then reads the app's own lines (FR-620):
the last keep-awake line must show the state the app wanted (waiting up to 90 s for launchd's
restart of the helper and the app's retries), the helper's start line must name the version
just installed while keep-awake is wanted, and the window count from the window server
(`scripts/count-windows.swift`) must be 0 unless the app logged why setup opened. The decisions
are functions in `install-lib.sh`, tested in `scripts/tests/install_checks_test.sh`. Options
considered: a fixed delay before deciding (rejected: a guess about timing), a UI test of the
real app (rejected: needs a second Mac or account for first-run states; the installer check
covers the installed Mac every time).

### D16. Diagnostic log in macOS's unified log
Serves FR-620; Constitution VI (nothing new stored by Latchkey: macOS keeps and ages its own
log). `Shared/Diagnostics.swift` holds one `Logger` per category under the app's subsystem:
`keepawake`, `helper`, `connection`, `power`, `permissions` (the existing `lifecycle` and
`activity` stay). States checked every few seconds pass through `Changes`, which lets a line
through only when it differs from the last. Interpolated values are private by default; only
fixed states, error descriptions, close codes and reasons, and app bundle IDs are `.public`.
Read with `log show --predicate 'subsystem == "net.melisma.latchkey"'`. Options considered: a
file of our own (rejected: another store to protect and age), the activity log (rejected: it
records Claude's actions, and these are the app's own). Changed 2026-10-27 (FR-633): macOS
discarded these lines within hours, so each one is now also an event in the activity log (D19);
the lines in macOS's log stay, with an `audit` category added.

### D19. Mac audit trail
Serves FR-026, FR-610, FR-632 to FR-634, FR-636, FR-637; Constitution II, VI. Options and the
measurements are in research.md ("The Mac's audit trail").
- Stored shape: `SealedActivity` gains `kind` ("action" or "event"), `callID`, and `device` in
  the clear, with defaults, so SwiftData upgrades Toni's log in place (old rows read as actions
  without a call id). The chain's checksum covers the three whenever one isn't its default, so
  old checksums still hold and a changed kind or id breaks the chain. The Claude app's name
  (`client`, FR-637) is sealed with the content. `AuditTrailTests` upgrades a chained log in the
  0.8.15–0.8.23 schema and checks every entry, the chain, and the record.
- Events (FR-633): `EventLog` (App/EventLog.swift), callable from any thread, writes each event
  to macOS's log (FR-620, same categories, `audit` added) and into the activity log, waiting in
  memory until the log is open and keeping events after a failed save. The kinds are
  `EventCategory`: app (start, quit, uninstall, errors shown), connection (connects, closes with
  code and reason, retries, network changes), keep-awake decisions (only on change), the
  helper's failures as the app sees them (once until they go away), power (sleep, wake,
  shutdown), permissions (requests, answers, every change of the approvals line), setup
  decisions, pause, pairing (paired, links, Disconnect, revoked), activity-log problems that
  can be recorded, and audit results. The menu shows Claude's actions only; the Activity window
  has a Show filter (everything, Claude's actions, Latchkey events) and a Claude App column;
  Export adds `kind`, `call_id`, and `client`.
- Left Behind (FR-640 to FR-643): a further `EventCategory`, `leftovers`, recorded with
  `systemLog: false`. The Show filter gains Left Behind (events of that category). A tool result
  carries `made` (what it created, "the note “Plan”"), which the app records as "Claude made
  …" after the call. Shell's entries and the notification are spec 004 D10, D11.
- Calls (FR-632, FR-637): each action stores the `call`'s `id`, the pairing's device ID, and the
  `client` it named.
- Comparison (FR-634): after each `welcome` (the connection's `connected` hook, not awaited by
  it) and from Check Against Relay in the Activity window, the app asks for the relay's audit
  from the start, 1,000 rows a page, 15 s per page, and checks each page (no more than asked,
  nothing before `since`, `next_since` past the newest row, a million rows in all).
  `AuditComparison.compare` is a pure function; its result is one event naming every missing
  call ("Audit check: 412 calls match; missing on the Mac: call_… (tool, time); …" or "Audit
  check: all 412 calls match"), also in macOS's log under `audit`, and a warning in the Activity
  window while any is missing. A relay that doesn't answer in time gives "Audit check not
  possible: the relay didn't answer". Older relays aren't supported (Toni, 2026-10-27).
- Installer (FR-636): `install.sh` waits up to two minutes for the new app's "Audit check" line
  and fails (`audit_verdict` in install-lib.sh) on anything but "Audit check: all …", an
  unpaired Mac excepted.
- No age-based deletion anywhere on the Mac: `AuditTrailTests` keeps events 20 years old and
  checks that no app code deletes activity rows; uninstall removes the whole file.

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
  - Agent protocol: a Go test agent that speaks `contracts/agent-protocol.md`, including bad
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
| III. Disabled means nonexistent | Pass (FR-061); Pause leaves levels as they are and answers calls like an offline Mac (D15) |
| IV. Good macOS citizen | Pass with one documented exception: no App Sandbox (D9) |
| V. Self-hostable | Pass (D10) |
| VI. Store the minimum | Pass (D11, D12, D14, data-model.md): a grant's label and times, and the operator's own actions for a year |
| VII. Test-first | Planned (testing strategy) |
| VIII. Simplicity | Pass: relay, Mac app, specs |
| IX. Open source | Pass: Apache-2.0; all dependencies MIT, BSD, or Apache |
