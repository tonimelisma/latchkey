# 0005. OAuth authorization server: zitadel/oidc plus Claude's client registration methods

- Status: accepted
- Date: 2026-10-27
- Alias: plan 001 D4 (`specs/001-core/plan.md`, "D4. OAuth authorization server: zitadel/oidc plus Claude's client registration methods")

## Context and problem

Decision D4 of spec 001's plan (Core: connect Claude to the Mac); requirements in
[requirements/core.md](../requirements/core.md). Requirement IDs it cites: FR-040, FR-014, FR-180, FR-185, FR-183, FR-095, FR-181, FR-182, FR-184, SC-07, FR-098, FR-049a, FR-096, FR-097, FR-044.
The design it belongs to: [design/core.md](../design/core.md).

## Decision

Serves FR-040, FR-014, FR-180 to FR-185.
- `github.com/zitadel/oidc/v3` (Apache-2.0, OpenID-certified; its `op` package) since
  2026-10-27, replacing `github.com/ory/fosite` (decided 2026-10-27; research.md, "Replacing
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
  - Which clients are accepted (FR-180 to FR-185; decided 2026-10-25: "Claude only" out of the
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
    it gets "Claude only", never "anyone". Tests and the end-to-end checks (`internal/e2e`,
    `cmd/e2e`, `cmd/linuxcheck`), which register a throwaway client, set `*`.
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
- Consent is asked every time (FR-049a; decided 2026-10-25, replacing the remembered approval of
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

## Confirmation

The tests that validate the requirements it cites:

- `relay/internal/account/account_test.go`
- `relay/internal/oauth/allowed_internal_test.go`
- `relay/internal/oauth/allowed_test.go`
- `relay/internal/oauth/carryover_test.go`
- `relay/internal/oauth/code_twice_test.go`
- `relay/internal/oauth/oauth_test.go`
- `relay/internal/oauth/storage_internal_test.go`
- `relay/internal/oauth/token_client_test.go`
- `relay/internal/server/harness_test.go`
- `relay/internal/store/signin_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
