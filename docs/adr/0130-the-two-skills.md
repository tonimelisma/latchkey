# 0130. The two skills (FR-1103, FR-1104, FR-1106, FR-1107)

- Status: withdrawn with spec 011, 2026-11-01 (kept as the record)
- Date: 2026-11-01
- Alias: plan 011 D3 (`specs/011-claude-plugin/plan.md`, "D3. The two skills (FR-1103, FR-1104, FR-1106, FR-1107)")

## Context and problem

Decision D3 of spec 011's plan (The Claude plugin (withdrawn)); requirements in
[requirements/claude-plugin.md](../requirements/claude-plugin.md). Requirement IDs it cites: none current.
The design it belongs to: [design/claude-plugin.md](../design/claude-plugin.md).

## Decision


- `latchkey`: loads when the person asks for something on their own computer or server. It
  holds what tool descriptions can't (research R5): no tools available → hand over to setup;
  choosing a machine (`machines` first when unsure; ask when two fit; say which was used); the
  state line; an offline or asleep machine (say so once with what brings it back, no retry
  loop, offer another online machine); a refusal (explain what the Owner can change on that
  machine, never route around it); finding before acting; long jobs; tasks across machines.
- `set-up-latchkey`: the three pieces (relay, machines, connector); connecting Claude on
  claude.ai, Desktop, phones, and Claude Code; adding this plugin; pairing a Mac; pairing a
  Linux server; checking with `machines`; common failures (no tools in a chat, sign-in expired,
  machine offline, lost passkey, relay down). The relay guide stays a separate file read only
  when needed, since it is long and needs Claude Code's shell.

Both name no capability and no tool except `machines` (research R6). The relay guide's one
mention of screenshots becomes "pictures".

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
