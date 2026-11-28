# 0048. Running

- Status: accepted
- Date: 2026-10-22
- Alias: plan 004 D2 (`specs/004-shell/plan.md`, "D2. Running")

## Context and problem

Decision D2 of spec 004's plan (Shell); requirements in
[requirements/shell.md](../requirements/shell.md). Requirement IDs it cites: FR-301, FR-306.
The design it belongs to: [design/shell.md](../design/shell.md).

## Decision


Each command runs as `/usr/bin/script -q /dev/null /bin/zsh -l -c -- <command>`: `script` gives it
a real terminal session (prompts work, Ctrl-C reaches the program), the login shell loads the
Owner's PATH. Latchkey talks to `script` through pipes; no fork in the app. Environment adds
`TERM=dumb`, `NO_COLOR=1`, `PAGER=cat`, `GIT_PAGER=cat`. Folder: as given, else home (FR-301).
Runs as the Owner's user, never through the helper (FR-306).

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
