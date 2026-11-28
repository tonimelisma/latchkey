# 0021. Every permission at first run (FR-623, FR-606)

- Status: accepted
- Date: 2026-10-31
- Alias: plan 001 D20 (`specs/001-core/plan.md`, "D20. Every permission at first run (FR-623, FR-606)")

## Context and problem

Decision D20 of spec 001's plan (Core: connect Claude to the Mac); requirements in
[requirements/core.md](../requirements/core.md). Requirement IDs it cites: FR-623, FR-606.
The design it belongs to: [design/core.md](../design/core.md).

## Decision


Every approval in the Permissions tab is needed whatever the levels, so setup lists every step
and a missing one opens it. `AppModel.allowAll()` runs right after pairing (both the sign-in
window and a pairing link) and from setup's Ask Now button: it asks, one at a time and
waiting for each answer, Notifications (`requestAuthorization`), Contacts, Calendars, Reminders,
Location (waits up to a minute for Core Location's answer), control of every scripted app
(`Permissions.scriptedApps`, the app opened hidden first), Local Network, and macOS's direct
screen access question; then `openSwitches()` opens System Settings at the first switch still
off (`AppModel.Switch`: keep-awake, Full Disk Access, Screen Recording with its screenshot,
Accessibility), and every look at the approvals (each second while a window is open) opens the
next page once one turns on. Screen Recording turned on brings the throwaway screenshot once.
Nothing asks during use: notifications are posted without asking. The setup window groups the
approvals into four steps (connect, macOS's questions, System Settings, Safari), each a
checklist; a refused question shows "Open…" to its own System Settings page.

- Local Network has no call that reads it. Options: (a) a Bonjour search for a type declared in
  NSBonjourServices, which runs when allowed and waits with DNS-SD's "policy denied" (-65570)
  when not, and whose start makes macOS ask; (b) a UDP packet to the router, which says nothing
  back about the approval; (c) not checking, only asking once. Chosen: (a), remembered between
  starts and looked at again at most every 10 seconds while not allowed (`LocalNetwork.check`).
  Shell commands count as Latchkey's own, so this is the question a command reaching a printer
  or router would raise.
- macOS asks a second question at an app's first ScreenCaptureKit screenshot. Options: a
  throwaway 64×40 screenshot in setup (chosen, `ScreenCapture.confirm`), or leaving it to the
  first `computer_look`. Remembered once it went through.
- The test host never runs the Local Network check: it is its own app to macOS, and the question
  would land on the Owner's screen (it did once while this was written).

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/MenuTests.swift`
- `macos/Tests/RegressionSeamsTests.swift`
- `macos/Tests/SetupRenderTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
