# 0022. macOS's monthly screen question while the Owner is here (FR-624)

- Status: accepted
- Date: 2026-10-31
- Alias: plan 001 D21 (`specs/001-core/plan.md`, "D21. macOS's monthly screen question while the Owner is here (FR-624)")

## Context and problem

Decision D21 of spec 001's plan (Core: connect Claude to the Mac); requirements in
[requirements/core.md](../requirements/core.md). Requirement IDs it cites: FR-624.
The design it belongs to: [design/core.md](../design/core.md).

## Decision


Since macOS 15, an app that captures the screen with ScreenCaptureKit is asked again about once
a month ("continue to allow"), at its first screenshot after a date macOS keeps in
`~/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist`
(`kScreenCapturePrivacyHintDate` under the app's bundle ID; readable with Full Disk Access).
Options:
- (a) Read that date each minute; once it has passed and the Owner is at the Mac (any input
  within 60 s, `CGEventSource`; screen not locked, `CGSessionCopyCurrentDictionary`), take the
  throwaway screenshot `ScreenCapture.confirm`, at most once an hour. Pros: public calls only,
  nothing changed in macOS's records. Cons: the question can't be brought on before its date, so
  an Owner away from the date until Claude's next screenshot still meets it.
- (b) Write a later date into macOS's record. Pros: no question at all. Cons: changes a privacy
  record macOS protects, may stop working with any update, and goes against Constitution IV.
- (c) Apple's Persistent Content Capture entitlement, granted on request for screen-sharing
  apps. Pros: Apple's own way. Cons: an application to Apple; not known whether it is granted
  to an app like this.
- (d) Apple's picker (`SCContentSharingPicker`). Needs the Owner at each capture.

Chosen: (a), in `ScreenReminder` and `AppModel.remindScreenWhileHere`. (c) is open for the maintainer.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/ScreenReminderTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
