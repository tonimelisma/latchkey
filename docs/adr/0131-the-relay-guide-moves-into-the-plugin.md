# 0131. The relay guide moves into the plugin (FR-1105, FR-1113)

- Status: withdrawn with spec 011, 2026-11-01 (kept as the record)
- Date: 2026-11-01
- Alias: plan 011 D4 (`specs/011-claude-plugin/plan.md`, "D4. The relay guide moves into the plugin (FR-1105, FR-1113)")

## Context and problem

Decision D4 of spec 011's plan (The Claude plugin (withdrawn)); requirements in
[requirements/claude-plugin.md](../requirements/claude-plugin.md). Requirement IDs it cites: none current.
The design it belongs to: [design/claude-plugin.md](../design/claude-plugin.md).

## Decision


`docs/setup-with-claude.md` moves (git history kept) to
`plugin/skills/set-up-latchkey/own-relay.md`, and the Mac app's Copy Request points at its raw
GitHub address. No copy stays at the old path: the Mac app isn't distributed yet, and the maintainer's
installed app gets the new address in this change. The guide's "Connect Claude" step adds the
plugin. Links in README, docs/self-hosting.md, spec 009, and the guide check program follow.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
