# 0016. Menu bar: state in the icon's shape, a short menu, a Settings window, Pause

- Status: accepted
- Date: 2026-10-26
- Alias: plan 001 D15 (`specs/001-core/plan.md`, "D15. Menu bar: state in the icon's shape, a short menu, a Settings window, Pause")

## Context and problem

Decision D15 of spec 001's plan (Core: connect Claude to the Mac); requirements in
[requirements/core.md](../requirements/core.md). Requirement IDs it cites: FR-070, FR-076, FR-190, FR-600, FR-605, FR-131, FR-132, FR-606, FR-604, FR-602, FR-066, FR-603.
The design it belongs to: [design/core.md](../design/core.md).

## Decision

Serves FR-070, FR-076, FR-190, FR-600 to FR-605, spec 002 FR-131 and FR-132; Constitution II,
III, IV. Guidance checked against Apple's Human Interface Guidelines (research.md, "Menu bar
design", 2026-10-26).
- Icon: SF Symbols `key.fill` (reachable) and `key.slash` (not reachable; Apple's slash variant
  for "unavailable"), with at most one small mark beside the key: `pause.fill`, `exclamationmark`,
  or the existing dot. A pure function of (connection status, paused, setup unfinished, calls
  running) picks it, so a unit test covers every case. Template images only, no color.
- Menu, top to bottom: status line (and the suspension advice, the keep-awake problem, or the
  last error when there is one); Keep Mac Awake, Pause/Resume Claude's Access; Recent Activity
  (the newest five, then Show All Activity…); Settings… (⌘,), Check for
  Updates… when available; Quit Latchkey (⌘Q). The battery line is gone.
- Activity titles: "time  Capability: target", the capability from the tool's prefix and the
  target from the first of `command`, `path`, `url`, `query`, `to`, `title`, `app`, `action` in
  the arguments, on one line, at most 40 characters; without one, the tool's own title.
- Settings window: SwiftUI's `Settings` scene with a tab per pane (What Claude Can Do,
  Permissions, Claude Apps, Connection, General), which gives the toolbar, the pane title, ⌘, and reopening the last
  pane. Opened from the menu with `openSettings`, then the app is activated (a menu bar app's
  window would otherwise open behind others). The Claude Apps pane shows the whole list, so the separate "Show All Apps…" window is gone.
- Permissions pane (FR-606): a pure function turns what the app's checks found (the same ones
  setup uses) and the levels into one row per permission: allowed, missing (the levels need it;
  exactly what makes setup unfinished), not needed, or optional (Contacts after "Don't Allow").
  Its buttons call the setup steps' actions; while the pane is open it re-checks every second,
  as the setup window does. Setup stays the first-run walk-through and opens itself only when
  something is missing.
- Pause is the Mac's own state, stored in user defaults so it survives restarts (FR-604). The
  relay doesn't change: the tools stay listed, as they do while the Mac is offline, and every
  call is answered at once with the pause error (FR-602), so nothing waits (II). Capability
  levels are untouched, so III holds. Pausing stops running calls through the same path as a
  lowered level (FR-066) and stops every shell job (FR-603). Refused calls are logged in the
  activity like any other.
- Disconnect This Mac asks first with an alert: "Disconnect" (destructive style, Return doesn't
  press it) and "Cancel", as Remove Access… already does (FR-605).

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/ClientAccessTests.swift`
- `macos/Tests/LevelChangeTests.swift`
- `macos/Tests/MenuTests.swift`
- `macos/Tests/ProtocolFixtureTests.swift`
- `macos/Tests/SetupRenderTests.swift`
- `relay/internal/hub/clients_test.go`
- `relay/internal/oauth/carryover_test.go`
- `relay/internal/oauth/grants_test.go`
- `relay/internal/server/clients_test.go`
- `relay/internal/store/grants_test.go`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
