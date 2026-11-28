# 0045. Search

- Status: accepted
- Date: 2026-10-22
- Alias: plan 003 D4 (`specs/003-files/plan.md`, "D4. Search")

## Context and problem

Decision D4 of spec 003's plan (Files); requirements in
[requirements/files.md](../requirements/files.md). Requirement IDs it cites: none current.
The design it belongs to: [design/files.md](../design/files.md).

## Decision


`mdfind` (Spotlight) as a process, name or content, optional folder, newest first; with a 20 s
deadline. `mdfind` has no `--`, so a query starting with `-` gets a leading space, which Spotlight
ignores, and is never read as an option such as `-live` (security scan, 2026-10-24). The answer notes that Spotlight skips hidden and excluded folders.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
