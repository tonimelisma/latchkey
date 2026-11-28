# 0002. NAT traversal: the Mac app keeps one outbound WebSocket to the relay

- Status: accepted
- Date: 2026-10-19
- Alias: plan 001 D1 (`specs/001-core/plan.md`, "D1. NAT traversal: the Mac app keeps one outbound WebSocket to the relay")

## Context and problem

Decision D1 of spec 001's plan (Core: connect Claude to the Mac); requirements in
[requirements/core.md](../requirements/core.md). Requirement IDs it cites: FR-002, FR-004, FR-012, SC-04, FR-036a, SC-05, FR-091, FR-092, FR-052a, FR-093.
The design it belongs to: [design/core.md](../design/core.md).

## Decision

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

## Confirmation

The tests that validate the requirements it cites:

- `relay/agentproto/agentproto_test.go`
- `relay/internal/hub/clients_test.go`
- `relay/internal/hub/hub_internal_test.go`
- `relay/internal/hub/hub_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
