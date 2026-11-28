# 0057. Changes that got past the fence (FR-325)

- Status: accepted
- Date: 2026-10-27
- Alias: plan 004 D11 (`specs/004-shell/plan.md`, "D11. Changes that got past the fence (FR-325)")

## Context and problem

Decision D11 of spec 004's plan (Shell); requirements in
[requirements/shell.md](../requirements/shell.md). Requirement IDs it cites: FR-325.
The design it belongs to: [design/shell.md](../design/shell.md).

## Decision


The permanent places of D9 are watched with `DispatchSource` file-system sources (the home
folder's top level for the startup files, the launch agents folder, the login items folder;
cheap, no recursive watch). A change while a job runs or is kept, at a path no live job
declared, is a Left Behind entry and a notification ("A command Claude ran may have changed …").

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/LeftoversTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
