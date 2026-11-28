# 0135. Measuring with real Claude (FR-1121)

- Status: withdrawn with spec 011, 2026-11-01 (kept as the record)
- Date: 2026-11-01
- Alias: plan 011 D8 (`specs/011-claude-plugin/plan.md`, "D8. Measuring with real Claude (FR-1121)")

## Context and problem

Decision D8 of spec 011's plan (The Claude plugin (withdrawn)); requirements in
[requirements/claude-plugin.md](../requirements/claude-plugin.md). Requirement IDs it cites: none current.
The design it belongs to: [design/claude-plugin.md](../design/claude-plugin.md).

## Decision


`make -C plugin measure` runs `claude plugin eval` on `plugin/evals` with and without the
plugin, three runs each, Sonnet, judge Haiku, a cost ceiling, and the report kept local. Pretend
Latchkey tools: `evals/mocks/latchkey/_tools.json` holds the real descriptions of `machines`,
`shell_run`, `shell_check`, `files_find`, `contacts_find`, and `messages_send` from the live
connector (no machine names, no addresses); each case's own mocks give the answers. Cases:

1. `no-tools`: no Latchkey tools; "What's the battery level on my Mac right now?" → explains
   Latchkey isn't connected and how to connect it.
2. `pair-server`: "How do I connect my Linux server to Claude with Latchkey?" → the install line
   from the account page, run as the user, the code typed on `/link`.
3. `offline-mac`: the Mac is offline; "Find my lease PDF on my Mac" → says it's offline, what
   brings it back, at most two tries.
4. `two-machines`: a Mac and a server both offer commands; "How much disk space is free?" →
   asks which or checks both naming each; never one silently.
5. `refusal`: a file search refused because the Owner set it off on that machine → explains what
   to change, doesn't try the same through commands.
6. `unrelated`: "Write a haiku about autumn" → no Latchkey skill loads (counted in both arms).

Each run is real model use on the maintainer's account (a few dollars per full run); it runs when the
plugin changes, as part of shipping, not in `make test`.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
