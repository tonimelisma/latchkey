# The Claude plugin (withdrawn): design

GOVERNS: nothing (the plugin was deleted with spec 011)

Spec 011's plan (migrated from `specs/011-claude-plugin/plan.md`, titled "Spec 011 plan: HOW"). What it must do:
[requirements/claude-plugin.md](../requirements/claude-plugin.md). Each decision Dn is an ADR, linked
where the decision stood.

Sources: research.md. Contract: contracts/plugin.md.

## D1. A plugin of skills only (FR-1101, FR-1102, FR-1106)

Decision record: [ADR 0128](../adr/0128-a-plugin-of-skills-only.md).

## D2. Where it lives (FR-1110)

Decision record: [ADR 0129](../adr/0129-where-it-lives.md).

## D3. The two skills (FR-1103, FR-1104, FR-1106, FR-1107)

Decision record: [ADR 0130](../adr/0130-the-two-skills.md).

## D4. The relay guide moves into the plugin (FR-1105, FR-1113)

Decision record: [ADR 0131](../adr/0131-the-relay-guide-moves-into-the-plugin.md).

## D5. Versions (FR-1111)

Decision record: [ADR 0132](../adr/0132-versions.md).

## D6. Telling the Owner (FR-1112)

Decision record: [ADR 0133](../adr/0133-telling-the-owner.md).

## D7. Content checks (FR-1120; Constitution VII, tests first)

Decision record: [ADR 0134](../adr/0134-content-checks.md).

## D8. Measuring with real Claude (FR-1121)

Decision record: [ADR 0135](../adr/0135-measuring-with-real-claude.md).

## D9. Shipping (CLAUDE.md "Every increment ships")

Decision record: [ADR 0136](../adr/0136-shipping.md).

## Choices made for the maintainer (he asked for no questions; all eight approved by him in chat, 2026-11-01)

1. Skills only, no connector in the plugin; the hosted-relay variant waits for the directory.
2. Repository layout of D2 (catalog at the root, plugin in `plugin/`, its own Makefile).
3. Two skills, named `latchkey` and `set-up-latchkey`.
4. The relay guide moves into the plugin, with no copy left at the old path.
5. Versioning of D5, enforced by the content check.
6. A line on the relay's account page and a README step about the plugin.
7. Measuring with `claude plugin eval` on pretend tools, Sonnet, before each plugin release.
8. Constitution VIII: the maintainer dropped its project count instead (below).

## Constitution check

- I, II: unchanged; the plugin adds no connection and no waiting.
- III: the skills name no capability and no tool but the relay's `machines`; checked (C5).
- IV: nothing runs on the person's computer; nothing to leave behind.
- V: works with every relay; no vendor.
- VI: the plugin stores nothing; the relay stores nothing new.
- VII: content checks written first and seen failing; behavior measured with real Claude.
- VIII: the plugin serves FR-1101 to FR-1121 and adds no program, layer, or dependency; the
  check forbids anything that runs in it. (VIII's project count, copied from Spec Kit's template
  on 2026-10-19, was dropped on 2026-11-01.)
- IX: Apache-2.0, as the repository.
