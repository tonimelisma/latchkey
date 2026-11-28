# 0145. Where the copies live (FR-1310, FR-1305)

- Status: accepted
- Date: 2026-11-21
- Alias: plan 013 D1 (`specs/013-sign-in/plan.md`, "D1. Where the copies live (FR-1310, FR-1305)")

## Context and problem

Decision D1 of spec 013's plan (Signing in); requirements in
[requirements/sign-in.md](../requirements/sign-in.md). Requirement IDs it cites: FR-1310, FR-1305, FR-1303.
The design it belongs to: [design/sign-in.md](../design/sign-in.md).

## Decision


One generic-password item in the login keychain, account `sign-ins`, under the app's own Keychain
service (`AppIdentity`), through the existing `Keychain` helper: accessible after first unlock,
this device only (readable while locked, as the pairing is; `docs/research/2026-11-20-sign-in.md`), trusting only this
app. Its data is JSON: the import's date and the list of `SavedSignIn` (title, site, user name,
password, `otpauth` address). Tests use a memory vault (the `PairingVault` protocol;
`KeychainVault` writes nothing under XCTest). Removing (menu, uninstall watcher in
`Installation.swift`) deletes the item. Options weighed: one item per sign-in (hundreds of
Keychain items, slower list, partial imports possible) vs one item (all or nothing for free,
FR-1303); one item chosen.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/SignInDataTests.swift`
- `macos/Tests/SignInImportTests.swift`
- `macos/Tests/SignInStoreTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
