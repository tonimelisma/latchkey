# 0003. The relay is the MCP server, not a pass-through

- Status: accepted
- Date: 2026-10-19
- Alias: plan 001 D2 (`specs/001-core/plan.md`, "D2. The relay is the MCP server, not a pass-through")

## Context and problem

Decision D2 of spec 001's plan (Core: connect Claude to the Mac); requirements in
[requirements/core.md](../requirements/core.md). Requirement IDs it cites: FR-010, FR-013, FR-014, SC-03, SC-07, FR-062, FR-066, FR-310, FR-090.
The design it belongs to: [design/core.md](../design/core.md).

## Decision

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

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/LevelChangeTests.swift`
- `macos/Tests/ShellTests.swift`
- `relay/internal/mcpserver/mcpserver_test.go`
- `relay/internal/oauth/oauth_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
