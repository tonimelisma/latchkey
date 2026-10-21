# Latchkey

Your Mac, at Claude's fingertips from anywhere. A native Swift menu bar app keeps an outbound
WebSocket to an always-on Go relay; the relay is the MCP server Claude connects to as a custom
connector. Claude on web, Desktop, iOS and Android can then use the Mac behind a home router, and
gets an immediate, clear answer when the Mac is offline. Free, open source, self-hostable.
Apple silicon, current + previous macOS. Owner: Toni Melisma (`tonimelisma`).

**At the start of every session, read `docs/STATUS.md`** (current phase, next step, open
questions). Then read the spec folder you are working in.

## "Do the next step"

When Toni says "next step", "continue", or similar: take the first item under "Next steps" in
`docs/STATUS.md`, do it following the process below, verify it, then update `docs/STATUS.md`
(mark it done, write the new next steps) and commit. Stop and report in plain language when the
step is done or needs a decision from Toni.

## Source of truth

- `memory/constitution.md`: nine principles every plan must pass. Change only with Toni's approval.
- `specs/NNN-name/`: `spec.md` (what/why), `plan.md` (how), `research.md`, `data-model.md`,
  `contracts/`, `tasks.md`. Specs win over every other doc.
- `docs/decisions.md`: index of approved decisions, linking to spec IDs. Don't re-ask these.
- Topic rules load automatically from `.claude/rules/` when you touch matching files.

## Development process (spec-driven)

1. Specify what and why in `spec.md`. No technology. Requirements in EARS form ("When X, the
   system shall Y") with stable IDs: never renumber; mark removed ones "withdrawn".
2. Mark anything undecided `[NEEDS CLARIFICATION: ...]`. Never guess.
3. Plan the how in `plan.md`; every decision names the requirements it serves; end with the
   constitution check.
3a. Before a plan, contract, or task list is done, check that it holds together: every
   requirement has a mechanism in the plan and, where it crosses the relay–Mac boundary, a
   message in the contracts; no two docs contradict each other; milestone order matches the
   dependencies. Fix gaps that follow from the spec; ask Toni only where the spec leaves a real
   choice. Never hand Toni a plan with known gaps.
4. Break into `tasks.md`; each task testable, parallel-safe ones marked `[P]`.
5. Implement test-first: contract and integration tests written and seen failing first.
   Integration tests use a real MCP client, not mocks.
6. New capabilities get their own `specs/NNN-name/` on branch `NNN-name`, one at a time, in this
   order: files, Notes + iMessage, shell, browser and computer control. Start each with research
   (existing MCP servers, macOS APIs, permissions, risks) and an interview of Toni; stop for
   Toni's review before writing tasks or code.

IMPORTANT: specs, `docs/STATUS.md`, and `docs/decisions.md` are updated in the same commit as the
code or decision that changes them. Never let them drift.

## Working with Toni

- Plain, short language. Lead with the answer. Explain unavoidable jargon in a few words.
- Never use internal labels with Toni (milestone codes like M1, task IDs like T015, requirement
  IDs, command names like `make run`) without saying in words what they are. Questions especially
  must make sense to someone who hasn't read the plan.
- No manual work for Toni. Claude runs every test and check itself, scripted. Ask Toni only for
  what only Toni can do (his accounts, his devices, approvals), keep it to the minimum, and say so
  plainly up front.
- Toni wants complete solutions, not partial matches. Say plainly when something falls short.
- When work is blocked on something only Toni can do, build everything around it, prepare the
  blocked step so it is a single action for him, and list all such steps together at the end.

## Toni decides

IMPORTANT: Toni makes every product and engineering choice. Claude proposes; Toni picks.

- Wording and visual design users see (pages, emails, menus, icons): Claude drafts it, reviews it
  against Apple's Human Interface Guidelines and common usability guidance, and never asks Toni
  to confirm it.
- Ask Toni about: features and behavior users see, libraries and tools, architecture,
  repository layout, protocol or schema shape, milestone and task order, test approach, temporary
  workarounds, user-facing defaults. Never make one of these silently.
- Don't ask about low-level implementation details (encodings, internal function names, private
  helpers, file names inside a package). Decide them yourself: weigh two or three options, pick
  one, and record options, pros and cons, and the choice in `research.md` or the contract.
- Ask with the AskUserQuestion tool: multiple choice, recommended option first with a one-line
  why. Batch related questions (up to 4 per call).
- Anything not already settled in a spec, plan, or `docs/decisions.md` is undecided. Ask before
  acting on it, and never write it into a doc as if it were settled.
- When a task needs choices, ask them all before starting the work, not after.
- Don't re-ask what `docs/decisions.md` already records.
- Record each answer in the spec or plan and in `docs/decisions.md`, in the same commit.

## Git

- Private remote `github.com/tonimelisma/latchkey`, default branch `main`.
- Branch per spec or task: `NNN-short-name`. Small commits. Open PRs only when asked.
- Push the branch after every finished step, and fast-forward `main` to it (Toni, 2026-10-20).
  Never force-push.

## Gotchas

- `~/Development/Relay` is an unrelated project. This repo is `~/Development/latchkey`.
- The relay must never wait on the Mac without a deadline (Constitution II).
- A capability the user turned off must not appear to Claude at all (Constitution III).

## Commands

Relay (run in `relay/`):
- `make test`: all tests, with the race detector (includes a headless-Chrome test; skipped if
  Chrome is missing)
- `make test-short`: the same without the browser test
- `make claude-check`: real Claude Code against a private relay and the pretend Mac
- `make lint`: golangci-lint (pinned in the Makefile) with gofumpt; must report 0 issues
- `make fmt`: format
- `make run`: run locally with development defaults (data in `relay/.data/`)

- `make mac-check`: the Mac app's real connection code against a private relay (battery vs
  pmset, tool off, silent network cut, reconnect)

Hosted relay: `deploy/deploy-vps.sh` deploys to https://relay.example.com on GCP `my-vm`
(project my-gcp-project) behind its Caddy; needs `CLOUDFLARE_API_TOKEN` and `RESEND_API_KEY`
(send-only) in the gitignored `.env`, plus `RESEND_ADMIN_KEY` (full access) for the first run that
sets up the sending domain.

Mac app (run in `macos/`; `project.yml` is the source, the `.xcodeproj` is generated):
- `make test`: unit and contract tests (Swift Testing); exit code is the result
- `make lint` / `make fmt`: swift-format
- `make build` / `make run`: build, or build and open the app
- `make dmg`: the installable disk image, `build/Latchkey-<version>.dmg`
- Signing: copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set your team ID

<!-- Maintainers: keep this file under ~100 lines. Status and decisions live in docs/, topic
knowledge in .claude/rules/, multi-step procedures in docs/. Test each line: would removing it
cause Claude to make mistakes? -->
