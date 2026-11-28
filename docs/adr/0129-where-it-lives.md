# 0129. Where it lives (FR-1110)

- Status: withdrawn with spec 011, 2026-11-01 (kept as the record)
- Date: 2026-11-01
- Alias: plan 011 D2 (`specs/011-claude-plugin/plan.md`, "D2. Where it lives (FR-1110)")

## Context and problem

Decision D2 of spec 011's plan (The Claude plugin (withdrawn)); requirements in
[requirements/claude-plugin.md](../requirements/claude-plugin.md). Requirement IDs it cites: none current.
The design it belongs to: [design/claude-plugin.md](../design/claude-plugin.md).

## Decision


```
.claude-plugin/marketplace.json        the catalog: one plugin, source ./plugin
plugin/                                the plugin (what people install)
  .claude-plugin/plugin.json           name latchkey, version, description, license, links
  README.md                            what it is, how to add it
  skills/latchkey/SKILL.md             using the machines (FR-1103)
  skills/set-up-latchkey/SKILL.md      setting up and fixing (FR-1104)
  skills/set-up-latchkey/own-relay.md  the relay guide, moved from docs/setup-with-claude.md (FR-1105)
  evals/                               cases and pretend Latchkey tools (FR-1121)
  tests/check.sh, contract_test.sh     content checks and their tests (FR-1120)
  Makefile                             test, lint, measure
```

The catalog sits at the repository root so `tonimelisma/latchkey` is all a person types. The
catalog and the plugin are both named `latchkey`, so it installs as `latchkey@latchkey` and its
skills show as `latchkey:latchkey` and `latchkey:set-up-latchkey`. Considered: the plugin under
`relay/` (the relay serves the tools it describes), rejected because the plugin covers the Mac
app and the Linux program too, has its own version, and a change to it must not trigger a relay
deploy.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
