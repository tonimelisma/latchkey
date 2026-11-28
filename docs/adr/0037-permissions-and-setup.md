# 0037. Permissions and setup

- Status: accepted
- Date: 2026-10-21
- Alias: plan 002 D5 (`specs/002-notes-messages/plan.md`, "D5. Permissions and setup")

## Context and problem

Decision D5 of spec 002's plan (Notes and Messages); requirements in
[requirements/notes-messages.md](../requirements/notes-messages.md). Requirement IDs it cites: FR-140, FR-121.
The design it belongs to: [design/notes-messages.md](../design/notes-messages.md).

## Decision


Serves FR-140, FR-121.
- `Info.plist`: `NSAppleEventsUsageDescription`, `NSContactsUsageDescription`. Entitlement:
  `com.apple.security.automation.apple-events` (hardened runtime).
- Full Disk Access cannot be requested: the app checks by opening the databases; when missing, the
  setup window adds a step "Allow Latchkey to read Notes and Messages" with a button that opens
  System Settings → Privacy & Security → Full Disk Access. The window notices the change by itself.
- Automation is asked for in setup, not on first use: a prompt raised by a request from the phone
  would wait on an unattended Mac. The step ("Let Latchkey change your notes") opens Notes in the
  background and lets macOS ask (`AEDeterminePermissionToAutomateTarget`); after a denial it
  opens System Settings → Automation. macOS can only tell while Notes runs, so an Allow once seen
  is remembered. A denial at call time is explained in the tool result. Contacts prompts on
  first use (increment 4).
- Levels start at Read & write (FR-121), so setup shows these steps on first launch.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/CapabilityTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
