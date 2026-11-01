# Contract: what Claude sees

## Connector URL

```
https://<relay>/mcp
```

The Owner adds this once at claude.ai → Settings → Connectors → Add custom connector. Every user of
a relay uses the same URL; the OAuth token identifies the Owner and therefore their machines (spec 010).

## HTTP endpoints

| Path | Purpose | Called by |
|---|---|---|
| `POST/GET/DELETE /mcp` | MCP Streamable HTTP | Anthropic's cloud |
| `GET /.well-known/oauth-protected-resource` and `/.well-known/oauth-protected-resource/mcp` | RFC 9728 metadata | Anthropic's cloud |
| `GET /.well-known/oauth-authorization-server` | RFC 8414 metadata | Anthropic's cloud |
| `GET /authorize` | Sign-in and consent page | The Owner's browser (any device) |
| `POST /token` | Code exchange, refresh (`application/x-www-form-urlencoded`) | Anthropic's cloud, Claude Code |
| `POST /register` | Dynamic client registration (`application/json`); off unless the operator allows every client host (below) | Clients that can't publish a metadata document |
| `POST /revoke` | Token revocation | Clients |
| `GET /terms`, `GET /privacy` | Terms of service and privacy policy; `404` unless the operator set `OPERATOR_NAME` and `OPERATOR_CONTACT` (FR-193) | Anyone's browser |

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
  "scopes_supported": ["mcp", "offline_access"],
  "authorization_response_iss_parameter_supported": true
}
```

With the default `ALLOWED_CLIENT_HOSTS` (or any list other than `*`) there is no
`registration_endpoint`, and `token_endpoint_auth_methods_supported` and
`revocation_endpoint_auth_methods_supported` are `["none"]`. The metadata above is what the relay
serves with `ALLOWED_CLIENT_HOSTS=*`. `client_id_metadata_document_supported: true` and `none`
are always there: they make Claude identify itself with a metadata document.

Where the operator has set `OPERATOR_NAME` and `OPERATOR_CONTACT` (FR-193), the metadata also
carries the two RFC 8414 fields below; otherwise neither appears.

```json
{
  "op_tos_uri": "https://<relay>/terms",
  "op_policy_uri": "https://<relay>/privacy"
}
```

## Which clients are accepted (FR-180 to FR-185)

`ALLOWED_CLIENT_HOSTS` is a comma-separated list of exact host names, default `claude.ai`; `*`
alone means any host. With a list:

- `client_id` must be an HTTPS metadata document URL whose host is on the list (lowercase, IDNA
  ASCII form, exact match, no subdomains; the port is ignored). Claude's are
  `https://claude.ai/oauth/mcp-oauth-client-metadata` (web, Desktop, mobile, Cowork) and
  `https://claude.ai/oauth/claude-code-client-metadata` (Claude Code).
- Every redirect URI in the document must be on a listed host or on a loopback host.
- A client that fails either rule is answered `401` `invalid_client` with
  `error_description` ending in "This relay only accepts Claude's apps." (with another list:
  "This relay only accepts apps from <hosts>."), at `/authorize` as a page in the browser with
  no redirect, and at `/token` as JSON. The relay makes no request to a host that isn't listed.
- `POST /register` answers `403`:
  `{"error":"access_denied","error_description":"This relay only accepts Claude's apps. Registering a client is turned off; identify the client with a client ID metadata document."}`
- Clients stored under a wider list, with their codes and tokens, are deleted at start and daily.

## Authorization responses

`GET /authorize` always shows the consent page (after sign-in if needed); nothing is approved
without the Owner pressing Allow, however often the same client was allowed before (FR-049a).
The redirect back to the client carries `code`, `state`, `scope`, and `iss` (RFC 9207, the
relay's issuer, exactly as in the metadata); an error redirect carries `error`,
`error_description`, `state`, and `iss`. A client that checks `iss` must find the issuer it
started with.

## Client metadata documents

A `client_id` that is an HTTPS URL with a path is fetched from public addresses only, at most 64
KiB, within 5 s. The document is cached for its `Cache-Control: max-age`, at least 5 minutes
(also with `no-store`) and at most 24 hours. If a refresh fails, the previous copy is used for up
to 7 more days and the URL is not fetched again for 5 minutes. A document that can't be used is
answered with `invalid_client` and no detail about the fetch.

## Redirect URIs accepted

A redirect URI must be listed in the client's CIMD document or DCR registration (and, with a
list of allowed client hosts, be on one of them or on a loopback host). For loopback
URIs (`http://localhost`, `http://127.0.0.1`, `http://[::1]`) the port is ignored, since Claude
Code picks a new port each time. In practice:

- `https://claude.ai/api/mcp/auth_callback` (claude.ai web, Desktop, mobile, Cowork)
- `http://localhost:<any>/callback` and `http://127.0.0.1:<any>/callback` (Claude Code)

Registered redirect URIs must be `https`, or `http` on a loopback host. The consent screen shows
the redirect URI's host, and names the client by its `client_name` followed by the host the relay
checked: the metadata document's host for a CIMD client (its client ID), otherwise the redirect
URI's host, e.g. "Claude (claude.ai)". A client's name alone is never shown, since anyone can
register one called "Claude". Hosts are shown in ASCII (`xn--` form for internationalized
names); the name loses control and formatting characters and brackets of every kind (ASCII and
all other Unicode opening and closing punctuation) and is cut to 60 characters.

## One approval, one grant (FR-190, FR-191)

Each Allow on the consent page creates one grant: the code, the access tokens, and the refresh
tokens that descend from it. The relay keeps, per grant, what the consent page showed (name,
checked host, where the approval was sent back to), when it was approved, and when it was last
used (written at most once a minute). The Owner can remove one grant on the account page or in
the Mac app; its tokens and codes are deleted, so the next request with them gets the `401`
above and a refresh gets `invalid_grant`, and its open MCP sessions are closed. Other grants,
also of the same client ID, are not touched.

## Suspended accounts (FR-196)

While the relay's operator has suspended an account, every token of the account is gone and
`/mcp` answers the `401` above; `/authorize` leads to the sign-in page, which refuses the
account with a message naming the operator's contact address when one is set.

## Token endpoint behavior

- Responds within 2 s in normal operation (Claude allows 10 s, 30 s for refresh).
- Invalid or expired refresh token: `400` with `{"error": "invalid_grant"}`.
- An authorization code works once. Presented again, or by two requests at once, it gets
  `400` `invalid_grant`, and the tokens issued for it stop working (FR-096).
- Refresh rotates the refresh token and returns the new one in the same response.

## Tools

Since spec 010 the tool list is the union of the account's paired machines' last reported lists
(FR-013; spec 010 FR-1004, plan D2), plus the relay's own `machines` tool while at least one
machine is paired. With nothing paired the list is empty. (Until spec 010: the one Mac's list,
and no relay tool; the 2026-10-22 status tool stays withdrawn.)

- A name offered by one kind of machine: that kind's definition, from its most recently seen
  machine. Offered by Macs and Linux servers with different definitions: one tool whose
  description is "On a Mac: …" then, after a blank line, "On a Linux server: …"; the input
  properties united (a property only one kind has ends its description with "(Mac only)" or
  "(Linux servers only)"; enum values united; required only what both require); read-only and
  idempotent only if both are, destructive and open-world if either is; the longer deadline;
  the output schema only if both are equal.
- Every machine tool gets the optional property `machine` (string): "The machine to use, by name,
  as the machines tool lists it. Leave it out when only one machine offers this tool." The relay
  removes it before forwarding.
- `machines` (read-only, no arguments) answers in text only (structured content would hide it in
  Claude's apps):

```
Your machines (2):
- Toni's MacBook Pro · Mac (macOS 26.1) · online · 64% battery, on battery power · keep-awake on · offers: shell_run, notes_find, …
- homeserver · Linux server (Debian GNU/Linux 12 (bookworm)) · online · up 12 days · offers: files_change, files_find, files_read, shell_check, shell_run
Pass a machine's name as machine when more than one offers a tool.
```

An offline machine shows "offline, last seen 3 hours ago" (or "offline, never connected"); a
machine with every capability off shows "offers no tools (all turned off on it)".

The `initialize` result carries these instructions: "Latchkey reaches the owner's own machines:
Macs and Linux servers. The machines tool lists them, whether each is online, and what each
offers. When more than one machine offers a tool, pass the machine's name as machine; when only
one does, leave it out. Every answer ends with the answering machine's state and the other
machines."

### Choosing the machine (spec 010 FR-1005, FR-1007)

Named (letter case and surrounding spaces aside): that machine; one that doesn't offer the tool
is answered as if the tool didn't exist there. Not named: the only machine offering the tool, or
the only online one among several; otherwise no guess. Refusals are results with `isError: true`
and no state line:

| Situation | Text returned |
|---|---|
| Several offer it, not one alone online | "Several machines offer shell_run: Toni's MacBook Pro (Mac, online), homeserver (Linux, online). Name one with machine." |
| Unknown name | "No machine is called "pi". Your machines: Toni's MacBook Pro (Mac, online), homeserver (Linux, offline, last seen 2 hours ago)." |
| Named machine lacks the tool | "homeserver doesn't offer notes_find. It's offered by: Toni's MacBook Pro (Mac, online)." |
| No machine offers it | "No machine offers shell_run." |
| Nothing paired | "No machine is connected to this account yet. Open the Latchkey app on your Mac and click Connect, or install Latchkey on a Linux server." |

### The machine's state in every answer (FR-065, spec 010 FR-1009)

Every result from a machine tool, success or the machine's own error, ends with one extra text
block, built by the relay from the state it holds: the answering machine's line and, when the
account has other machines, a second line naming them (Toni, 2026-10-31):

```
Toni's MacBook Pro (Mac): online · 64% battery, on battery power · keep-awake on
Other machines: homeserver (Linux, online)
```

```
homeserver (Linux): online · up 12 days
Other machines: Toni's MacBook Pro (Mac, offline, last seen 3 hours ago)
```

The block always starts on a line of its own (FR-200). Claude's apps join a result's text blocks
with nothing between them, so the relay puts one line break at the start of the added block
unless the result's last block that shows something is text already ending in a line break
(empty text blocks are skipped; a result with nothing in it needs none). After an image or any
other non-text block the line break is always added. The machine's own blocks are never changed.

- Mac power: "on battery power", "plugged in", "charging", or "on UPS power".
- Mac keep-awake: "keep-awake on", "keep-awake off", "keep-awake off (battery low)", "keep-awake
  off (too hot)", "keep-awake off (not approved in System Settings)".
- Mac warnings appended: "battery low: the Mac goes to sleep at 15%" (on battery at 25% or less),
  "the Mac is too hot and may go to sleep" (thermal serious or critical).
- Linux uptime: "up 12 days" (two days or more), "up 5 hours" (two hours or more), "up 20 minutes".

When the machine cannot answer, the result is the explanation below instead, which carries the
last known state (and, when offline, the other machines' line).

## Results when a machine tool cannot run

All are normal `tools/call` results with `isError: true`, so Claude can explain them to the user.
They are never transport errors or HTTP failures. Since spec 010 they name the machine (until
then: "Your Mac").

| Situation | Text returned |
|---|---|
| Paired, never connected | "Toni's MacBook Pro is offline. It hasn't connected to Latchkey yet." |
| Offline, reason known | "Toni's MacBook Pro is offline. It went to sleep for low battery at 14%, at 2:02 PM (3 hours ago)." |
| Offline, reason unknown | "Toni's MacBook Pro is offline. It was last seen at 2:02 PM (3 hours ago) with 62% battery, on battery power." |
| Linux server offline | "homeserver is offline. It shut down at 2:02 PM (3 hours ago)." / "… Latchkey was stopped on it at …" / "… It was last seen at …" |
| Deadline passed | "homeserver didn't answer within 5 seconds. It may be busy or losing its connection." |
| Revoked during call | "homeserver was disconnected from this account while the request was running." |
| Connection lost during call | "homeserver lost its connection while the request was running." |
| Unreadable result | "homeserver sent a result the relay couldn't read." |

Other known Mac offline reasons: too hot ("It went to sleep because it was too hot, at …"), system
sleep ("It went to sleep at …"), shutdown ("It shut down at …"), app quit ("The Latchkey app was
quit at …"). A time on an earlier day adds the date: "at 3:02 PM on Oct 17 (2 days ago)".

Times are rendered in the machine's time zone (reported in state, FR-037) plus a relative time,
for example "at 2:02 PM (3 hours ago)". If the time zone is unknown, UTC is used and labeled.
