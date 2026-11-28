# 0064. Levels

- Status: accepted
- Date: 2026-10-22
- Alias: plan 005 D5 (`specs/005-browser/plan.md`, "D5. Levels")

## Context and problem

Decision D5 of spec 005's plan (Browser control); requirements in
[requirements/browser.md](../requirements/browser.md). Requirement IDs it cites: FR-407, FR-408.
The design it belongs to: [design/browser.md](../design/browser.md).

## Decision


New capability `browser`, levels Off / Read only / Read & write, starting Read & write (FR-407).
Clicks, typing, and scripts return an activity for the trace and the menu (FR-408); they don't
notify, as one task can mean dozens of clicks.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/BrowserActionTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
