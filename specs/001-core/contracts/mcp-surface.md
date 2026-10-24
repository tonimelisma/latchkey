# Contract: what Claude sees

## Connector URL

```
https://<relay>/mcp
```

The Owner adds this once at claude.ai → Settings → Connectors → Add custom connector. Every user of
a relay uses the same URL; the OAuth token identifies the Owner and therefore the Mac.

## HTTP endpoints

| Path | Purpose | Called by |
|---|---|---|
| `POST/GET/DELETE /mcp` | MCP Streamable HTTP | Anthropic's cloud |
| `GET /.well-known/oauth-protected-resource` and `/.well-known/oauth-protected-resource/mcp` | RFC 9728 metadata | Anthropic's cloud |
| `GET /.well-known/oauth-authorization-server` | RFC 8414 metadata | Anthropic's cloud |
| `GET /authorize` | Sign-in and consent page | The Owner's browser (any device) |
| `POST /token` | Code exchange, refresh (`application/x-www-form-urlencoded`) | Anthropic's cloud, Claude Code |
| `POST /register` | Dynamic client registration (`application/json`) | Anthropic's cloud, Claude Code |
| `POST /revoke` | Token revocation | Clients |

## Unauthenticated request to /mcp

```http
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer resource_metadata="https://<relay>/.well-known/oauth-protected-resource/mcp", scope="mcp offline_access"
```

The status must be 401; Claude ignores `WWW-Authenticate` on other statuses. The same 401 answers
a bearer value that is not a live access token, a refresh token included (refresh tokens are for
`POST /token` only; security scan, 2026-10-24).

## Protected resource metadata

```json
{
  "resource": "https://<relay>/mcp",
  "authorization_servers": ["https://<relay>"],
  "scopes_supported": ["mcp", "offline_access"],
  "bearer_methods_supported": ["header"]
}
```

`resource` must equal the connector URL exactly.

## Authorization server metadata (required fields)

```json
{
  "issuer": "https://<relay>",
  "authorization_endpoint": "https://<relay>/authorize",
  "token_endpoint": "https://<relay>/token",
  "registration_endpoint": "https://<relay>/register",
  "revocation_endpoint": "https://<relay>/revoke",
  "response_types_supported": ["code"],
  "grant_types_supported": ["authorization_code", "refresh_token"],
  "code_challenge_methods_supported": ["S256"],
  "token_endpoint_auth_methods_supported": ["none", "client_secret_post", "client_secret_basic"],
  "client_id_metadata_document_supported": true,
  "scopes_supported": ["mcp", "offline_access"]
}
```

## Redirect URIs accepted

A redirect URI must be listed in the client's CIMD document or DCR registration. For loopback
URIs (`http://localhost`, `http://127.0.0.1`, `http://[::1]`) the port is ignored, since Claude
Code picks a new port each time. In practice:

- `https://claude.ai/api/mcp/auth_callback` (claude.ai web, Desktop, mobile, Cowork)
- `http://localhost:<any>/callback` and `http://127.0.0.1:<any>/callback` (Claude Code)

Registered redirect URIs must be `https`, or `http` on a loopback host. The consent screen shows
the redirect URI's host, and names the client by its `client_name` followed by the host the relay
checked: the metadata document's host for a CIMD client (its client ID), otherwise the redirect
URI's host, e.g. "Claude (claude.ai)". A client's name alone is never shown, since anyone can
register one called "Claude".

## Token endpoint behavior

- Responds within 2 s in normal operation (Claude allows 10 s, 30 s for refresh).
- Invalid or expired refresh token: `400` with `{"error": "invalid_grant"}`.
- Refresh rotates the refresh token and returns the new one in the same response.

## Tools

The relay offers no tools of its own (status tool withdrawn 2026-10-22, spec 001 FR-021). The tool
list is the Mac's last reported list (FR-013): the tools of each capability at its current level
(spec 002). With no Mac paired, or every capability off, the list is empty.

### The Mac's state in every answer (FR-065)

Every result from a Mac tool, success or the Mac's own error, ends with one extra text block,
built by the relay from the state it holds:

```
Mac: online · 64% battery, on battery power · keep-awake on
```

- Power: "on battery power", "plugged in", "charging", or "on UPS power".
- Keep-awake: "keep-awake on", "keep-awake off", "keep-awake off (battery low)", "keep-awake off
  (too hot)", "keep-awake off (not approved in System Settings)".
- Warnings appended: "battery low: the Mac goes to sleep at 15%" (on battery at 25% or less), "the
  Mac is too hot and may go to sleep" (thermal serious or critical).

When the Mac cannot answer, the result is the explanation below instead, which carries the last
known state.

## Results when a Mac tool cannot run

All are normal `tools/call` results with `isError: true`, so Claude can explain them to the user.
They are never transport errors or HTTP failures.

| Situation | Text returned |
|---|---|
| Paired, never connected | "Your Mac is offline. It hasn't connected to Latchkey yet." |
| Offline, reason known | "Your Mac is offline. It went to sleep for low battery at 14%, at 2:02 PM (3 hours ago)." |
| Offline, reason unknown | "Your Mac is offline. It was last seen at 2:02 PM (3 hours ago) with 62% battery, on battery power." |
| Deadline passed | "Your Mac didn't answer within 5 seconds. It may be busy or losing its connection." |
| Revoked during call | "Your Mac was disconnected from this account while the request was running." |
| Connection lost during call | "Your Mac lost its connection while the request was running." |
| Unreadable result from the Mac | "Your Mac sent a result the relay couldn't read." |

Other known offline reasons: too hot ("It went to sleep because it was too hot, at …"), system
sleep ("It went to sleep at …"), shutdown ("It shut down at …"), app quit ("The Latchkey app was
quit at …"). Power phrases: "on battery power", "plugged in", "charging", "on UPS power". A time on
an earlier day adds the date: "at 3:02 PM on Oct 17 (2 days ago)".

Times are rendered in the Mac's time zone (reported in state, FR-037) plus a relative time, for
example "at 2:02 PM (3 hours ago)". If the time zone is unknown, UTC is used and labeled.
