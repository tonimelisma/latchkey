# 0026. Add Latchkey to Claude (FR-627, FR-628, FR-659, FR-660)

- Status: accepted
- Date: 2026-11-01
- Alias: plan 001 D25 (`specs/001-core/plan.md`, "D25. Add Latchkey to Claude (FR-627, FR-628, FR-659, FR-660)")

## Context and problem

Decision D25 of spec 001's plan (Core: connect Claude to the Mac); requirements in
[requirements/core.md](../requirements/core.md). Requirement IDs it cites: FR-627, FR-628, FR-659, FR-660, FR-192.
The design it belongs to: [design/core.md](../design/core.md).

## Decision


- The link is claude.ai's documented install link for a custom connector
  (claude.com/docs/connectors/building/directory-vs-custom):
  `https://claude.ai/customize/connectors?modal=add-custom-connector&connectorName=Latchkey&connectorUrl=<percent-encoded address>`.
  It only fills in the dialog; the Owner still clicks Add, signs in with the passkey, and
  clicks Allow. Nothing can add a connector to an account without the Owner (no API; `claude
  mcp add` reaches Claude Code only). The relay builds it with `url.QueryEscape`; the Mac app with
  `AddToClaude.link(relay:)`, encoding everything but letters, digits, and `-._~`.
- Done means an approval whose host is claude.ai or claude.com and that wasn't sent back to this
  computer: the same test the Settings window uses for "Covers Claude on the web, desktop, and
  phone" (`ClientEntry.coversHostedApps`, and `hostedClaude` on the relay). Options were (a)
  this, chosen: it is what "from anywhere" needs; (b) any approval, which a Claude Code sign-in
  would satisfy while the phone still can't reach the Mac.
- Mac app: the step is `setupSteps`' "Claude", known only while connected and the list of
  approvals has arrived (`access.entries`), so an offline Mac isn't nagged for it. The relay
  sends a new list when an approval is added or removed (FR-192), so the step ticks itself off.
  The step is also offered by the Settings window's Claude Apps tab (FR-628).
- Relay: `accountView.AddLink` and `HasClaude`; the page starts with a "Next: add Latchkey to
  Claude" panel while `HasClaude` is false, and the Claude section always has the button, the
  steps, and the address by hand.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/AddToClaudeTests.swift`
- `macos/Tests/ClientAccessTests.swift`
- `macos/Tests/ProtocolFixtureTests.swift`
- `relay/internal/account/account_test.go`
- `relay/internal/oauth/grants_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
