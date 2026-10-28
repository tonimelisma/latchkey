# Contract: Mac app ↔ relay agent protocol, v1

The Mac app ("agent") dials the relay. All messages are JSON objects in WebSocket text frames.
Every message has a `type`. Field names are snake_case. Unknown fields are ignored; unknown types
are an error (close 4005).

## Pairing (before the first connection)

The app pairs once, through the Owner's browser (plan D6):

1. The app opens `ASWebAuthenticationSession` at `https://<relay>/pair?name=<URL-encoded Mac name>`
   with callback scheme `latchkey`.
2. The Owner signs in with a passkey if needed and clicks Connect (or Replace and Connect, when
   another Mac is paired, FR-053).
3. The relay redirects to `latchkey://paired?code=<code>&relay=<relay origin>`. The code is
   single-use and expires in 5 minutes. The app's own sign-in window delivers the link straight
   to the app, which goes on to step 4. A link that reaches the app any other way (opened by the
   system from another browser, while a pairing is in progress or not) is used only after the
   Owner confirms a dialog naming the relay and the email of the code's account, and saying that
   it replaces the current pairing if there is one (FR-054). The link controls the relay, and the
   email is only what that relay answers, so the dialog's title names the relay and its text says
   "<relay> says this is the account <email>"; it also says when the relay differs from the one
   the Mac is paired with (or, unpaired, the one the app suggests). To get the email, the app first asks
   the relay, without using the code:

```http
POST /pair/preview
Content-Type: application/json

{"code": "<code>"}
```

```json
{"email": "owner@example.com"}
```

   Errors are `400` with the same `{"error": …}` as an expired code at `/pair/exchange` (unknown,
   used, or expired code), and `415` without the JSON content type. The endpoint shares the
   pairing endpoints' per-address rate limit. If the lookup fails, or the answer isn't one plain
   email address, the dialog says the link expired and offers no Connect button. If the Owner
   confirms while the sign-in window's pairing is open, that pairing is cancelled and the link's
   code is exchanged instead.
4. The app creates its Secure Enclave P-256 key and calls:

```http
POST /pair/exchange
Content-Type: application/json

{"code": "<code>", "public_key": "<PKIX DER, base64url unpadded>", "name": "Toni's MacBook Pro"}
```

```json
{"device_id": "dev_8f3k..."}
```

Errors are `400` with `{"error": "<sentence for the Owner>"}` (expired or used code, key not
P-256). On success, any previously paired Mac is revoked (closed with 4002). The app stores the
relay URL and `device_id` in its settings and the key in the Secure Enclave, then connects.

## Connection

```
GET wss://<relay>/agent/v1
Sec-WebSocket-Protocol: latchkey.v1
```

Limits: max frame 4 MiB. The relay closes connections that exceed it (code 1009).

Message rate (added 2026-10-25, FR-091): after `welcome`, the agent may send 60 messages at once
and then 5 per second on average (a token bucket: 60 tokens, one back every 200 ms). A `result`
or `progress` for a call the relay is still waiting on is not counted, so answering every
running call at once is always fine. Counted are `state`, `tools`, `goodbye`, and a `result` or
`progress` whose call the relay no longer waits on (timed out or cancelled). A message beyond
the allowance is a protocol violation (close 4005, reason "too many messages"). The app's own
traffic (a `state` every 15 s and on change, `tools` when capabilities change) stays far below
it.

## Handshake

1. relay → agent
```json
{"type": "challenge", "nonce": "<32 random bytes, base64url>", "server_time": "2026-10-19T17:02:11Z"}
```

2. agent → relay, within 10 s
```json
{
  "type": "hello",
  "device_id": "dev_8f3k...",
  "signature": "<base64url ECDSA P-256 signature over UTF-8 'latchkey-agent-v1\n' + nonce + '\n' + device_id>",
  "app_version": "0.1.0",
  "os_version": "26.1",
  "tools": [ /* MCP Tool objects, see below */ ],
  "state": { /* State object */ },
  "features": ["clients"]
}
```

`features` (optional, added 2026-10-25, FR-190) is an array of strings naming the later
additions to this protocol that the app understands. The app sends `["clients"]` when it
understands the `clients` and `revoke_client` messages below, and `"audit"` (2026-10-27) when it
understands `audit_request` and `audit`. Unknown strings are ignored, and
a missing `features` means none. The relay sends `clients` messages ONLY to an agent that listed
`"clients"`: the app up to 0.8.9 treats an unknown message type as a protocol violation.

Signature: ECDSA P-256 with SHA-256 over the UTF-8 bytes of
`"latchkey-agent-v1\n" + nonce + "\n" + device_id`, where `nonce` is the base64url string exactly
as received. Encoded as ASN.1 DER, then base64url without padding (RFC 4648 §5). All base64url
values in this protocol are unpadded.

3. relay → agent
```json
{"type": "welcome", "heartbeat_interval_s": 15, "server_time": "..."}
```
or the relay closes with a code from the table below.

Order of the relay's checks on `hello` (2026-10-25, FR-092): the frame must be JSON with `type`
`hello` (else 4005); then only `device_id` and `signature` are read and verified (else 4001);
only then are the tool list, state, and the other fields parsed and validated (else 4005). So a
hello with a wrong signature is answered 4001 whatever else it contains, and the relay does no
work on a stranger's tool list. Implementation choice: a second, small decode of the same frame
for the two fields (`agentproto.DecodeHelloAuth`) rather than a streaming parser or a separate
authentication message (which would change the wire format).

A device revoked while its handshake is in progress may still receive `welcome`; the relay then
closes with 4002 as soon as the connection is registered (FR-052a).

## State object

Sent in `hello`, in every `state` message, and in `goodbye`.

```json
{
  "battery_percent": 82,
  "power_source": "battery",          // "battery" | "ac" | "ups" | "unknown"
  "charging": false,
  "time_remaining_min": 312,          // null if unknown
  "thermal_state": "nominal",         // "nominal" | "fair" | "serious" | "critical"
  "low_power_mode": false,
  "lid_closed": true,                 // null if unknown
  "time_zone": "America/Los_Angeles", // IANA name; null if unknown
  "keep_awake": "on",                 // "on" | "off_user" | "off_low_battery" | "off_too_hot" | "off_helper_unavailable"
  "observed_at": "2026-10-19T17:02:10Z"
}
```

## Agent → relay messages

| type | When | Fields |
|---|---|---|
| `state` | Every `heartbeat_interval_s` and on any change: the first at once, further changes within the same second as one message when the second is over (FR-036a) | `state` |
| `tools` | Enabled capabilities changed | `tools` (full list, replaces the previous one) |
| `progress` | Optional, during a long call | `id`, `progress`, `total` (optional), `message` (optional) |
| `result` | A call finished, or the Owner stopped it by turning its capability off or down (then `is_error` with the reason, FR-066) | `id`, `content` (MCP content array), `structured_content` (optional), `is_error` |
| `goodbye` | Before an intentional disconnect | `reason`, `state` |
| `revoke_client` | The Owner removed one app's access in the Mac app (FR-191) | `id` (from the `clients` list) |
| `audit_request` | The app compares its log with the relay's audit (FR-634); only with the `audit` feature | `id`, `since`, `limit` |

`goodbye.reason`: `low_battery`, `too_hot`, `user_quit`, `system_sleep`, `system_shutdown`,
`user_disconnected`.

`user_disconnected` means the Owner clicked "Disconnect" in the app: the relay revokes the device
(deletes its public key) and closes with 4002. The app deletes its local key.

## Relay → agent messages

| type | When | Fields |
|---|---|---|
| `call` | Claude called a Mac tool | `id`, `tool`, `arguments`, `deadline_ms`, `client` (optional, added 2026-10-27, FR-637: the Claude app's name as the relay records it in its audit, e.g. "Claude Code"; empty or missing when unknown) |
| `cancel` | Deadline passed or Claude cancelled | `id`, `reason` (`deadline` or `client_cancelled`) |
| `notice` | Something the Owner must be told on the Mac | `kind`, `at`, `client` (optional) |
| `clients` | Right after `welcome`, and whenever the list changes; only to an agent that announced the `clients` feature (FR-190) | `clients` (full list, replaces the previous one) |
| `audit` | The answer to an `audit_request` (FR-634) | `id`, `entries`, `next_since` |

`notice.kind`: `account_recovered` (a recovery link was used, FR-042); `client_authorized` (a
Claude client was given access; `client` is its name with the host the relay checked, as on the
consent page, e.g. "Claude (claude.ai)"; added 2026-10-23, host added 2026-10-24).
Sent immediately if the device is online, otherwise right after `welcome` on its next connection;
each `client_authorized` is sent once. The app shows a macOS notification.

`id` is an opaque string unique for all time (since 2026-10-27, FR-632: `call_` followed by 26
characters of random base32, 128 bits); the relay stores it in its audit and the Mac in its
activity log. Older relays sent ids unique per connection only (`c_1`, `c_2`, …). The agent may
run calls concurrently. A `result` for an unknown or cancelled `id` is ignored.

## Apps with access (`clients`, `revoke_client`; added 2026-10-25, FR-190 to FR-192)

An "app with access" is one approval the Owner gave on the relay's Allow page that still has a
live access or refresh token (a grant). All of Claude's hosted apps share one client ID, so two
entries can name the same client; the unit that is listed and removed is the grant.

relay → agent:

```json
{"type": "clients", "clients": [
  {"id": "grt_k3v9x2m7q4w8z5n1", "name": "Claude", "host": "claude.ai", "redirect": "claude.ai",
   "approved_at": "2026-10-25T16:02:11Z", "last_used_at": "2026-10-25T17:40:00Z"},
  {"id": "grt_p8d2r6t1y7u3s9a4", "name": "Claude Code", "host": "claude.ai", "redirect": "this computer",
   "approved_at": "2026-10-24T09:15:00Z", "last_used_at": null}
]}
```

- The full list every time (it replaces the previous one), sorted newest approval first, at
  most 50 entries.
- `id`: opaque, stable for the grant, 1 to 64 characters of `[A-Za-z0-9_-]`. It is a public
  handle of the grant: not a token, not a token hash usable as a credential, not the client ID.
- `name` and `host` are exactly what the consent page showed, already cleaned: the client's own
  name, and the host the relay checked. A client that gave no name is listed as
  "An unnamed app".
- `redirect` is the host the approval was sent back to, or the literal `"this computer"` for a
  loopback redirect (`localhost`, `127.0.0.1`, `[::1]`).
- `approved_at` and `last_used_at` are RFC 3339 UTC; `last_used_at` is `null` until the grant is
  first used, and is updated at most once a minute (FR-192).
- Sent right after `welcome` (before any notices), and again whenever the list changes: a new
  approval (when its first token is issued), a removal (from the Mac, the account page, a
  recovery, revocation by the client, reuse detection), and when a grant is found expired by
  the relay's periodic purge. A change of `last_used_at` alone does not trigger a send. Account
  deletion and the Mac's own revocation close the connection (4002) instead.

agent → relay:

```json
{"type": "revoke_client", "id": "grt_k3v9x2m7q4w8z5n1"}
```

The relay removes that grant's tokens and codes if, and only if, the grant belongs to this
Mac's account; an `id` of another account, or an unknown one, changes nothing and is not an
error. Either way the relay then sends the new `clients` list (to an agent that announced the
feature). `revoke_client` is counted by the per-connection message allowance, like `state`. The
relay records it in its audit log as metadata only (time, "revoke_client", outcome), never the
`id`.

The app waits 5 seconds after `revoke_client` for a list without the entry and reports a
failure otherwise, so the relay answers at once, also when it removed nothing.

Validity (both sides; fixtures under `fixtures/invalid/`): a `clients` message whose `clients`
is not an array, has more than 50 entries, repeats an `id`, or has an entry with an `id` outside
`[A-Za-z0-9_-]{1,64}`, an empty or missing `name`, `host`, or `redirect`, or an `approved_at`
or `last_used_at` that is not an RFC 3339 time (or `null` for `last_used_at`) is a protocol
violation; so is a `revoke_client` whose `id` is outside that pattern. Times are sent in whole
seconds, UTC, with `Z`, and `last_used_at` is always present (`null` when never used).

Implementation choices (relay): the grant's public `id` is 16 random bytes, generated when the
Owner allows the app and stored beside the grant's internal request ID, rather than derived
from the request ID (which would make every stored ID guessable from one) or from a token
signature. The list is sent under a per-connection lock that covers reading it and writing it,
so two changes can't arrive in the wrong order; a list equal to the last one sent on the
connection (ignoring `last_used_at`) is not sent again, except in answer to `revoke_client`.

## Audit comparison (`audit_request`, `audit`; added 2026-10-27, FR-634)

Only from an agent that listed `"audit"` in `features`. Every relay must know these messages: no
backwards compatibility with older relays (Toni, 2026-10-27); the relay is deployed before an app
that sends them is installed.

agent → relay:
```json
{"type": "audit_request", "id": "a1", "since": 1793160000000, "limit": 1000}
```
`since`: milliseconds since 1970, inclusive. `limit`: 1 to 1000 (larger is cut to 1000).

relay → agent:
```json
{"type": "audit", "id": "a1", "entries": [
  {"call_id": "call_7Q2M…", "at": 1793160333843, "tool": "shell_run", "outcome": "ok", "duration_ms": 733}
], "next_since": 1793160333844}
```
Entries are this Mac's (`device_id` of the connection) audit rows with `at >= since`, oldest
first, at most `limit`. `next_since` is the `since` for the next page, or `null` when there are
no more. Rows from before call ids (FR-632) have `call_id` `""`. `outcome` is `ok`, `error`,
`timeout`, or `offline`; `offline` calls never reached the Mac and aren't expected in its log.
An `audit_request` with an out-of-range `since` or `limit` is answered with `entries` `[]` and
`next_since` `null`; one whose `since` or `limit` isn't a number, or whose `id` is missing or
longer than 128 bytes, is a malformed message (close 4005). An `audit_request` from an agent that
didn't list `"audit"` closes the connection with 4005. Entries with an empty `call_id` include
the Mac's own audited actions (`revoke_client`) as well as calls from before call ids; the
comparison leaves them all out and counts them.

Comparison on the Mac: over the same period, every relay entry with a `call_id` and an outcome
other than `offline` must have a log entry with that call id, and every log entry with a call id
must be among the relay's entries. A call still running (no relay entry yet, at most its
deadline old) is not counted as missing. A relay call missing from the Mac that is older than
the Mac's first logged call with an id (for this pairing) was made before the Mac's app could
store ids, and is counted with the calls from before call ids; with no id'd call in the Mac's
log, nothing is left out that way (2026-10-27). That point is never later than the switch-over
itself, 2026-10-28 05:38:15 UTC (app 0.8.24's first connection), so a wiped and refilled log
can't excuse later calls.

## Tools

Tool objects follow the MCP `Tool` shape (`name`, `title`, `description`, `inputSchema`,
`outputSchema`, `annotations`), plus one extension in `_meta`:

```json
{"_meta": {"latchkey/deadline_ms": 5000}}
```

`inputSchema` is required and must be a JSON Schema object with `"type": "object"`; `outputSchema`,
if present, likewise. Names use only letters, digits, `_`, `-`, and `.`, 1 to 128 characters (MCP
tool name rules). Anything else the relay's MCP SDK refuses is also a violation; today that is an
`x-mcp-header` annotation that isn't a non-empty HTTP token on a `string`, `integer`, or `boolean`
property, or repeats another (case-insensitive, at any depth). A tool list breaking these rules is
a protocol violation (close 4005).

Implementation choice (security scan, 2026-10-24): the relay checks the SDK's rules by trying
each tool on a throwaway SDK server and treating its panic as a refusal, rather than copying the
rules (which would drift when the SDK is updated) or only recovering at registration (which would
store a list the relay can't serve). Registration also recovers, as a second line, and leaves a
refused tool out.

The relay caps `deadline_ms` at 60000 (a declared deadline below 1 ms counts as 1 ms; one that
is not a positive number as the default). Tool names must not collide with relay tools
(`laptop_status`); the relay rejects a `tools` list that contains one (close 4005).

A tool list (in `hello` or `tools`) holds at most 256 tools and at most 512 KiB of JSON (the
`tools` value as sent); a larger one is a protocol violation (close 4005; added 2026-10-25,
FR-091). The app's full list today is 15 tools and a few tens of KiB. A `tools` message that
repeats the current list changes nothing: the relay neither stores it again nor tells Claude the
list changed.

## Liveness

- The relay marks the agent offline if it receives no frame for `2 × heartbeat_interval_s + 5`
  seconds (35 s by default).
- The relay also sends WebSocket ping frames every 15 s; the agent's WebSocket library answers them.

## Close codes

| Code | Meaning | Agent should |
|---|---|---|
| 1000 | Normal | Reconnect with backoff unless quitting |
| 4001, any reason but "account suspended" | Authentication failed (reason "authentication failed") | Show "Sign in again"; do not retry automatically; keep the local key and pairing |
| 4001, reason "account suspended" | The account is suspended by the relay's operator (FR-196) | Show "This account is suspended on the relay" and to contact the relay's operator, never "Sign in again"; keep the local key and pairing; try again every 5 minutes, and at once on wake or a network change (FR-204) |
| 4002 | Device revoked | Delete the local key; show "Disconnected from account" |
| 4003 | Replaced by a newer connection for this device | Do not reconnect from this connection |
| 4004 | Protocol version not supported | Show "Update required" |
| 4005 | Protocol violation (malformed or unknown message, invalid or oversized tool list, too many messages) | Reconnect with backoff; report a bug |
| 4006 | Handshake timeout | Reconnect with backoff |

Suspension (2026-10-25, FR-196): when the relay's operator suspends an account, the relay
closes the Mac's connection with 4001 and answers every new connection of that Mac with 4001
while the suspension lasts. It uses 4001 and never 4002 for this, because the app deletes its
key on 4002: a suspension must not make the Mac forget its pairing. The device and its key stay
stored on the relay, so the same pairing connects again once the suspension is lifted. The
close reason is the text "account suspended" (an ordinary failed authentication has
"authentication failed").

The agent tells the two apart by that reason, compared exactly; a 4001 with any other reason,
or none, is a failed authentication. While suspended it tries again every 5 minutes (no
backoff, no jitter: one Mac per account), and at once on wake or a network change, the triggers
of its normal reconnect (FR-204). Each attempt is refused in the handshake, after the signature
is verified and before anything is registered: one short connection and one database read. The
relay's per-address limit on `/agent/v1` (30 at once, then one every 2 seconds) is not reached
even by a Mac whose network changes every 10 seconds
(`TestASuspendedMacRetryingNeverReachesTheConnectionLimit`).
