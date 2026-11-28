# 0063. Setup and errors

- Status: accepted
- Date: 2026-10-22
- Alias: plan 005 D4 (`specs/005-browser/plan.md`, "D4. Setup and errors")

## Context and problem

Decision D4 of spec 005's plan (Browser control); requirements in
[requirements/browser.md](../requirements/browser.md). Requirement IDs it cites: FR-406.
The design it belongs to: [design/browser.md](../design/browser.md).

## Decision


The setup window gains two steps while Browser isn't Off (FR-406): Automation for Safari (as
for Notes and Messages), and "Allow JavaScript from Apple Events", with instructions and a
Check button that opens a blank Safari window, runs one line of script, and closes it (the
setting can't be read reliably from Safari's preferences). A tool that hits the missing setting
explains where to turn it on.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/BrowserTabTests.swift`
- `macos/Tests/BrowserTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
