# 0013. Apps with access: one row per approval, pushed to the Mac

- Status: accepted
- Date: 2026-10-24
- Alias: plan 001 D12 (`specs/001-core/plan.md`, "D12. Apps with access: one row per approval, pushed to the Mac")

## Context and problem

Decision D12 of spec 001's plan (Core: connect Claude to the Mac); requirements in
[requirements/core.md](../requirements/core.md). Requirement IDs it cites: FR-190, FR-191, FR-192, FR-091, FR-180, FR-184.
The design it belongs to: [design/core.md](../design/core.md).

## Decision

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

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/ClientAccessTests.swift`
- `macos/Tests/ProtocolFixtureTests.swift`
- `relay/agentproto/agentproto_test.go`
- `relay/internal/hub/clients_test.go`
- `relay/internal/hub/hub_test.go`
- `relay/internal/mcpserver/mcpserver_test.go`
- `relay/internal/oauth/allowed_internal_test.go`
- `relay/internal/oauth/allowed_test.go`
- `relay/internal/oauth/carryover_test.go`
- `relay/internal/oauth/grants_test.go`
- `relay/internal/oauth/token_client_test.go`
- `relay/internal/server/clients_test.go`
- `relay/internal/server/harness_test.go`
- `relay/internal/store/grants_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
