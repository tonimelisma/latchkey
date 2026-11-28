# 0015. Operator commands in the relay binary; the running relay follows the database

- Status: accepted
- Date: 2026-10-24
- Alias: plan 001 D14 (`specs/001-core/plan.md`, "D14. Operator commands in the relay binary; the running relay follows the database")

## Context and problem

Decision D14 of spec 001's plan (Core: connect Claude to the Mac); requirements in
[requirements/core.md](../requirements/core.md). Requirement IDs it cites: FR-195, FR-199, FR-204, FR-186, FR-189.
The design it belongs to: [design/core.md](../design/core.md).

## Decision

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
  function (what to show, when to retry). `make mac-check` suspended the account under the real
  connection code, checked what it showed, and lifted the suspension; removed 2026-11-26 (spec
  016 D2), it is the sandbox Mac's `suspended-account` check (`relay/e2e/sandbox-checks.md`).
- The operator log is purged after a year by the daily job.
- The commands open the database exactly as the server does, key file included (D10, FR-186):
  `DATA_DIR` and `KEY_FILE` from the container's environment. With the key file missing or
  wrong, a command refuses as the server would, changes nothing, and never makes a key file of
  its own beside sealed keys. `reset-keys` (FR-189) is a command of its own, for a stopped relay.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/ReconnectPolicyTests.swift`
- `relay/cmd/relay/operator_test.go`
- `relay/cmd/relay/resetkeys_test.go`
- `relay/internal/hub/suspend_test.go`
- `relay/internal/server/guard_test.go`
- `relay/internal/server/operator_test.go`
- `relay/internal/store/sealed_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
