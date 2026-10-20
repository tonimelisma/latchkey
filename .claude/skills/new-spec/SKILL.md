---
name: new-spec
description: Start a new Latchkey capability spec (e.g. 002-files) following the repo's spec-driven process, interviewing Toni for decisions.
argument-hint: NNN-short-name
---

Start spec `$ARGUMENTS` for Latchkey.

1. Read `memory/constitution.md`, `docs/STATUS.md`, `docs/decisions.md`, and
   `specs/001-core/spec.md` and `plan.md` for format and existing requirement IDs.
2. Create branch `$ARGUMENTS` from `main`.
3. Research: existing open-source MCP servers and macOS APIs for this capability, macOS privacy
   permissions it needs, and risks (prompt injection, data loss). Record findings with sources in
   `specs/$ARGUMENTS/research.md`.
4. Interview Toni with AskUserQuestion: scope, tools, what is off by default, risky actions,
   limits. Multiple choice, recommended default first. Don't re-ask anything in `docs/decisions.md`.
5. Write `specs/$ARGUMENTS/spec.md`: problem, user stories with priorities and acceptance
   scenarios (Given/When/Then), EARS requirements with new stable IDs, measurable success
   criteria, edge cases, open questions as `[NEEDS CLARIFICATION: ...]`. No technology.
6. Write `plan.md` (decisions traced to requirements, constitution check), plus `data-model.md`
   and `contracts/` if the capability changes them.
7. Update `docs/STATUS.md` and `docs/decisions.md`. Commit specs together.
8. Stop and summarize for Toni in plain language before writing `tasks.md` or any code.
