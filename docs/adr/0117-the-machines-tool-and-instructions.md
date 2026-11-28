# 0117. The machines tool and instructions (FR-1006)

- Status: accepted
- Date: 2026-10-31
- Alias: plan 010 D6 (`specs/010-multi-host/plan.md`, "D6. The machines tool and instructions (FR-1006)")

## Context and problem

Decision D6 of spec 010's plan (Several machines and Linux servers); requirements in
[requirements/multi-host.md](../requirements/multi-host.md). Requirement IDs it cites: FR-1006.
The design it belongs to: [design/multi-host.md](../design/multi-host.md).

## Decision


`machines` takes no arguments and answers one line per machine: name, kind, Latchkey and OS version (as last reported in hello),
online/last seen with the status line's facts, and what it offers (tool names; Files' level read
from whether `files_change` is there). Text only: with structured content present Claude's apps
show that instead of the text (live check 2026-10-22, `.claude/rules/macos.md`). The instructions
text (initialize) is fixed in mcp-surface.md.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
