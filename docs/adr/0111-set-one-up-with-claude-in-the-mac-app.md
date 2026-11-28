# 0111. "Set one up with Claude" in the Mac app (FR-903)

- Status: accepted
- Date: 2026-10-31
- Alias: plan 009 D9 (`specs/009-easy-relay-setup/plan.md`, "D9. "Set one up with Claude" in the Mac app (FR-903)")

## Context and problem

Decision D9 of spec 009's plan (Easy relay setup); requirements in
[requirements/easy-relay-setup.md](../requirements/easy-relay-setup.md). Requirement IDs it cites: FR-903.
The design it belongs to: [design/easy-relay-setup.md](../design/easy-relay-setup.md).

## Decision


- In setup's first step, under the relay address field: "Don't have a relay? Claude can set one
  up for you." with a Copy Request button. The request: "Set up a Latchkey relay for me. Follow
  the instructions at https://raw.githubusercontent.com/tonimelisma/latchkey/main/docs/setup-with-claude.md".
  A line says to paste it into Claude Code (the Code tab in Claude Desktop). Wording and layout
  reviewed against Apple's guidelines; README picture redrawn.

## Confirmation

The tests that validate the requirements it cites:

- `macos/Tests/SetupRequestTests.swift`

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
