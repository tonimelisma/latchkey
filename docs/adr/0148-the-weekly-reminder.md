# 0148. The weekly reminder (FR-1304)

- Status: accepted
- Date: 2026-11-21
- Alias: plan 013 D4 (`specs/013-sign-in/plan.md`, "D4. The weekly reminder (FR-1304)")

## Context and problem

Decision D4 of spec 013's plan (Signing in); requirements in
[requirements/sign-in.md](../requirements/sign-in.md). Requirement IDs it cites: FR-1304.
The design it belongs to: [design/sign-in.md](../design/sign-in.md).

## Decision


At start and every hour: when the reminder is on, the last import (or the first start of this
version, when there was none) is 7 days old or more, and no reminder went out in the last 7 days,
post one notification (category `signins.export`). A click starts D3. The setting and the dates
are in user defaults; never a window (Constitution IV).

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/SignInReminderTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
