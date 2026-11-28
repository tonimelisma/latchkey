# 0136. Shipping (CLAUDE.md "Every increment ships")

- Status: withdrawn with spec 011, 2026-11-01 (kept as the record)
- Date: 2026-11-01
- Alias: plan 011 D9 (`specs/011-claude-plugin/plan.md`, "D9. Shipping (CLAUDE.md "Every increment ships")")

## Context and problem

Decision D9 of spec 011's plan (The Claude plugin (withdrawn)); requirements in
[requirements/claude-plugin.md](../requirements/claude-plugin.md). Requirement IDs it cites: none current.
The design it belongs to: [design/claude-plugin.md](../design/claude-plugin.md).

## Decision


A plugin change: `make -C plugin test`, `make -C plugin measure`, version raised, commit,
fast-forward main; pushing to main publishes it. This change also touches the relay (account
page: tests, deploy) and the Mac app (Copy Request address: version 0.8.62, tests, install).
Live check: a fresh Claude Code session outside the repository with the plugin from the
published catalog, asked which machines it can reach and how to pair a server.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
