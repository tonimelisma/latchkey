# Contract: Mac app ↔ relay agent protocol, v1

The Mac app ("agent") dials the relay. All messages are JSON objects in WebSocket text frames.
Every message has a `type`. Field names are snake_case. Unknown fields are ignored; unknown types
are an error (close 4005).

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
  "time_zone": "America/Los_Angeles", // IANA name
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

## Relay → agent messages

| type | When | Fields |
|---|---|---|
| `call` | Claude called a Mac tool | `id`, `tool`, `arguments`, `deadline_ms` |
| `cancel` | Deadline passed or Claude cancelled | `id`, `reason` (`deadline` or `client_cancelled`) |

`id` is an opaque string unique per connection. The agent may run calls concurrently. A `result`
for an unknown or cancelled `id` is ignored.

## Tools

Tool objects follow the MCP `Tool` shape (`name`, `title`, `description`, `inputSchema`,
`outputSchema`, `annotations`), plus one extension in `_meta`:

```json
{"_meta": {"latchkey/deadline_ms": 5000}}
```

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
