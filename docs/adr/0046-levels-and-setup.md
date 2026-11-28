# 0046. Levels and setup

- Status: accepted
- Date: 2026-10-22
- Alias: plan 003 D5 (`specs/003-files/plan.md`, "D5. Levels and setup")

## Context and problem

Decision D5 of spec 003's plan (Files); requirements in
[requirements/files.md](../requirements/files.md). Requirement IDs it cites: FR-209.
The design it belongs to: [design/files.md](../design/files.md).

## Decision


New capability `files` in the registry, levels Off / Read only / Read & write, default Read &
write (FR-209). Needs Full Disk Access, the step setup already has (spec 002).

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
