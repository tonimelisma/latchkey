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
   it replaces the current pairing if there is one (FR-054). To get the email, the app first asks
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
  "state": { /* State object */ }
}
```

Signature: ECDSA P-256 with SHA-256 over the UTF-8 bytes of
`"latchkey-agent-v1\n" + nonce + "\n" + device_id`, where `nonce` is the base64url string exactly
as received. Encoded as ASN.1 DER, then base64url without padding (RFC 4648 §5). All base64url
values in this protocol are unpadded.

3. relay → agent
```json
{"type": "welcome", "heartbeat_interval_s": 15, "server_time": "..."}
```
or the relay closes with a code from the table below.

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
| `state` | Every `heartbeat_interval_s` and immediately on any change | `state` |
| `tools` | Enabled capabilities changed | `tools` (full list, replaces the previous one) |
| `progress` | Optional, during a long call | `id`, `progress`, `total` (optional), `message` (optional) |
| `result` | A call finished | `id`, `content` (MCP content array), `structured_content` (optional), `is_error` |
| `goodbye` | Before an intentional disconnect | `reason`, `state` |

`goodbye.reason`: `low_battery`, `too_hot`, `user_quit`, `system_sleep`, `system_shutdown`,
`user_disconnected`.

`user_disconnected` means the Owner clicked "Disconnect" in the app: the relay revokes the device
(deletes its public key) and closes with 4002. The app deletes its local key.

## Relay → agent messages

| type | When | Fields |
|---|---|---|
| `call` | Claude called a Mac tool | `id`, `tool`, `arguments`, `deadline_ms` |
| `cancel` | Deadline passed or Claude cancelled | `id`, `reason` (`deadline` or `client_cancelled`) |
| `notice` | Something the Owner must be told on the Mac | `kind`, `at`, `client` (optional) |

`notice.kind`: `account_recovered` (a recovery link was used, FR-042); `client_authorized` (a
Claude client was given access; `client` is its name, as on the consent page; added 2026-10-23).
Sent immediately if the device is online, otherwise right after `welcome` on its next connection;
each `client_authorized` is sent once. The app shows a macOS notification.

`id` is an opaque string unique per connection. The agent may run calls concurrently. A `result`
for an unknown or cancelled `id` is ignored.

## Tools

Tool objects follow the MCP `Tool` shape (`name`, `title`, `description`, `inputSchema`,
`outputSchema`, `annotations`), plus one extension in `_meta`:

```json
{"_meta": {"latchkey/deadline_ms": 5000}}
```

`inputSchema` is required and must be a JSON Schema object with `"type": "object"`; `outputSchema`,
if present, likewise. Names use only letters, digits, `_`, `-`, and `.`, 1 to 128 characters (MCP
tool name rules). A tool list breaking these rules is a protocol violation (close 4005).

The relay caps `deadline_ms` at 60000. Tool names must not collide with relay tools
(`laptop_status`); the relay rejects a `tools` list that contains one (close 4005).

## Liveness

- The relay marks the agent offline if it receives no frame for `2 × heartbeat_interval_s + 5`
  seconds (35 s by default).
- The relay also sends WebSocket ping frames every 15 s; the agent's WebSocket library answers them.

## Close codes

| Code | Meaning | Agent should |
|---|---|---|
| 1000 | Normal | Reconnect with backoff unless quitting |
| 4001 | Authentication failed | Show "Sign in again"; do not retry automatically |
| 4002 | Device revoked | Delete the local key; show "Disconnected from account" |
| 4003 | Replaced by a newer connection for this device | Do not reconnect from this connection |
| 4004 | Protocol version not supported | Show "Update required" |
| 4005 | Protocol violation | Reconnect with backoff; report a bug |
| 4006 | Handshake timeout | Reconnect with backoff |
