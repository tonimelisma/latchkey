# 0152. Where the Owner sees it (FR-1301, FR-1302, FR-1305)

- Status: accepted
- Date: 2026-11-21
- Alias: plan 013 D8 (`specs/013-sign-in/plan.md`, "D8. Where the Owner sees it (FR-1301, FR-1302, FR-1305)")

## Context and problem

Decision D8 of spec 013's plan (Signing in); requirements in
[requirements/sign-in.md](../requirements/sign-in.md). Requirement IDs it cites: FR-1301, FR-1302, FR-1305.
The design it belongs to: [design/sign-in.md](../design/sign-in.md).

## Decision


Settings → What Claude Can Do lists Sign-in with the other capabilities and, while it is on, a
section with how many sign-ins Latchkey holds and from when, Export from Passwords…, Remove All,
and the reminder switch. The menu has Export Passwords to Latchkey…. Setup gets a sixth step,
"Hand over your sign-ins (optional)", which never counts as missing (FR-1302).

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/SignInImportTests.swift`
- `macos/Tests/SignInStoreTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
