# 0008. Keep-awake: SMAppService helper daemon

- Status: accepted
- Date: 2026-10-19
- Alias: plan 001 D7 (`specs/001-core/plan.md`, "D7. Keep-awake: SMAppService helper daemon")

## Context and problem

Decision D7 of spec 001's plan (Core: connect Claude to the Mac); requirements in
[requirements/core.md](../requirements/core.md). Requirement IDs it cites: FR-030, FR-031, FR-035, FR-073, SC-09, FR-661.
The design it belongs to: [design/core.md](../design/core.md).

## Decision

Serves FR-030, FR-031, FR-035, FR-073; Constitution IV.
- Lid open, idle: the app itself holds an `IOPMAssertion` of type
  `PreventUserIdleSystemSleep`. Public API, no privileges.
- Lid closed: only the system `SleepDisabled` setting prevents clamshell sleep. That requires root,
  so a helper daemon registered with `SMAppService.daemon(plistName:)` performs exactly two
  operations: set it on and set it off, by running `/usr/bin/pmset -a disablesleep 1|0` (there is
  no public API for this setting).
- The Owner approves the helper once in System Settings → General → Login Items.
- XPC: Mach service; the helper accepts connections only from our app's code-signing requirement
  (`setCodeSigningRequirement`): the app's identifier, Apple's anchor, and the team the helper
  itself is signed with. In Release builds the requirement also refuses a caller that carries
  the debugging entitlement (`get-task-allow`), since any program running as the Owner can take
  over such a process; a Debug app and its Debug helper, which both carry it, accept each other,
  and the installed helper refuses a Debug app. The app checks the helper the same way. A build
  signed without a team has no requirement to check: the helper accepts nobody and the app
  doesn't connect at all (keep-awake then shows as needing the helper), rather than connecting
  unchecked (security review, 2026-10-25).
- Re-apply and verify on every power-source change (`IOPSNotificationCreateRunLoopSource`) and wake;
  read back the setting to confirm (FR-031).
- Restore: the app turns it off on quit; the helper turns it off when its client disconnects and on
  its own startup if no client connects within 60 s. That covers crashes and uninstall (FR-035,
  SC-09).
- `disablesleep` is not documented by Apple; its behavior is known from third-party apps
  (research.md), with conflicting reports about power-source changes on Apple silicon. The
  re-apply-and-read-back above is the mitigation. No separate spike or hardware test run
  (decided 2026-10-20).
- The session behind a closed lid (FR-038, FR-039 withdrawn; FR-661). Seen live with
  `SleepDisabled` on: after the lid closes, macOS keeps drawing the built-in screen and the
  session unlocked until a few minutes after the last activity, then drops the display and
  locks; locked, Mail's window, the screen, and Safari's scripting stop working. Options, least
  to most: (a) nothing, refuse plainly when locked; (b) wait for the Owner to unlock; (c) hold a
  public `PreventUserIdleDisplaySleep` assertion while the lid is closed and the session
  unlocked, and lock with macOS's own shortcut (Control-Command-Q, through the Accessibility
  setup already asks for) the moment the lid opens; (d) a virtual or plug-in monitor plus never
  requiring a password (private `CGVirtualDisplay` or hardware; weakens the lock for everyone).
  Chose (c) on 2026-11-01 (0.8.66); withdrawn 2026-11-02 (0.8.73, decided: "we're not
  circumventing security"): it kept the Mac's idle lock from coming, lid open or closed being
  no different. Now (a): what needs an unlocked session refuses plainly while locked (FR-661:
  Latchkey never holds off the idle lock), and ways to do some of it while locked are looked
  for capability by capability.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
