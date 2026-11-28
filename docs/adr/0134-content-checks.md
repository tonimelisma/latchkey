# 0134. Content checks (FR-1120; Constitution VII, tests first)

- Status: withdrawn with spec 011, 2026-11-01 (kept as the record)
- Date: 2026-11-01
- Alias: plan 011 D7 (`specs/011-claude-plugin/plan.md`, "D7. Content checks (FR-1120; Constitution VII, tests first)")

## Context and problem

Decision D7 of spec 011's plan (The Claude plugin (withdrawn)); requirements in
[requirements/claude-plugin.md](../requirements/claude-plugin.md). Requirement IDs it cites: none current.
The design it belongs to: [design/claude-plugin.md](../design/claude-plugin.md).

## Decision


`plugin/tests/contract_test.sh`, written and seen failing before the plugin existed, checks
contracts/plugin.md C1 to C7: layout and nothing that runs; manifest fields; catalog; skill
front matter; no capability or tool names but `machines`; no relay address or private values;
version raised. `make -C plugin test` runs it and `claude plugin validate --strict` on the
plugin and on the catalog. `relay`'s `script-tests` don't run it: the plugin has its own
Makefile like the other parts.

## Confirmation

No test validates the requirements it cites yet; reviewed by reading the code.

## Retirement proof

Not recorded when the decision was made (migrated from the plan). Before retiring it,
show that the requirements it cites are met another way or withdrawn.

## Reversal plan

Not recorded when the decision was made (migrated from the plan); write one when this
decision is next revisited.
