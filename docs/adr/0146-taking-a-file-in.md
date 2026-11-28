# 0146. Taking a file in (FR-1300, FR-1301, FR-1303)

- Status: accepted
- Date: 2026-11-21
- Alias: plan 013 D2 (`specs/013-sign-in/plan.md`, "D2. Taking a file in (FR-1300, FR-1301, FR-1303)")

## Context and problem

Decision D2 of spec 013's plan (Signing in); requirements in
[requirements/sign-in.md](../requirements/sign-in.md). Requirement IDs it cites: FR-1300, FR-1301, FR-1303.
The design it belongs to: [design/sign-in.md](../design/sign-in.md).

## Decision


A folder of Latchkey's own, `~/Library/Application Support/<app>/Sign-in Import` (0700, left out
of Time Machine with `isExcludedFromBackup`, never in iCloud Drive), watched while the app runs
(a file-system event source plus a check every 2 s). A `.csv` that appears there is read once it
stops growing, parsed (`PasswordsCSV`), stored (replacing everything, only when the whole file
parsed), overwritten with zeros, and deleted; the Owner gets a notification with the count. A
file that isn't Passwords' export is deleted too, and the notification says why. The folder is
where the one-touch export (D3) saves, and where the hand steps tell the Owner to save. Options
weighed: watching Downloads (needs that folder's permission, and the file could sync) vs a
private folder; the private folder chosen.

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
