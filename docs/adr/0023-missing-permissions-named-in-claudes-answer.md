# 0023. Missing permissions named in Claude's answer (FR-625)

- Status: accepted
- Date: 2026-10-31
- Alias: plan 001 D22 (`specs/001-core/plan.md`, "D22. Missing permissions named in Claude's answer (FR-625)")

## Context and problem

Decision D22 of spec 001's plan (Core: connect Claude to the Mac); requirements in
[requirements/core.md](../requirements/core.md). Requirement IDs it cites: FR-625.
The design it belongs to: [design/core.md](../design/core.md).

## Decision


- Automation: `OSAScriptRunner(app:)` asks `AEDeterminePermissionToAutomateTarget` without
  prompting before each script and, when macOS hasn't asked yet, throws `notAllowed` instead of
  running it. The answers send the owner to Latchkey's Settings → Permissions, which has a
  button for either case (never asked, or refused). An app that isn't running can't be checked
  that way, so it is opened hidden and looked at for up to 5 seconds
  (`Permissions.automationOpening`); its script would have opened it anyway.
- Local Network: a Shell answer whose output has "No route to host" gains a Local Network line
  while the last look found it not allowed (`LocalNetwork.refused`). macOS gives commands no
  other sign of this refusal.
- Full Disk Access taken back after a database was opened: the catch-all looks again
  (`Permissions.hasFullDiskAccess`) and gives the Full Disk Access answer.
- Files: macOS's privacy protection answers EPERM, a file's own permissions EACCES; only EPERM
  (anywhere in the error's chain) names Full Disk Access. Options were (a) EPERM, chosen; (b) a
  list of protected folders, which goes stale; (c) checking Full Disk Access on every failure,
  which also blames it for ordinary permission errors.
- Shell: its "write refused" hint gains a Full Disk Access line while Latchkey lacks it.
- Messages: a name that matches nobody says when Contacts isn't allowed.
- Screenshots: ScreenCaptureKit's `userDeclined` gets its own answer.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/PermissionAnswerTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
