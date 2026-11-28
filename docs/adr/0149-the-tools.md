# 0149. The tools (FR-1320, FR-1326, FR-1340, FR-1371; contract `contracts/login-tools.md`)

- Status: accepted
- Date: 2026-11-22
- Alias: plan 013 D5 (`specs/013-sign-in/plan.md`, "D5. The tools (FR-1320, FR-1326, FR-1340, FR-1371; contract `contracts/login-tools.md`)")

## Context and problem

Decision D5 of spec 013's plan (Signing in); requirements in
[requirements/sign-in.md](../requirements/sign-in.md). Requirement IDs it cites: FR-1320, FR-1326, FR-1340, FR-1371.
The design it belongs to: [design/sign-in.md](../design/sign-in.md).

## Decision


A capability `logins` ("Sign-in"), levels Off and On (On by default), with a read tool
`logins_find` and a write tool `logins_fill` (decided 2026-11-21: "Two: logins_find +
logins_sign_in", after the MCP research: a read-only tool is approved without asking in Claude's
apps; 2026-11-22: the write tool became `logins_fill`, "Fill-only tool"). Off: neither exists
(Constitution III).

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/SignInFillTests.swift`
- `macos/Tests/SignInToolsTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
