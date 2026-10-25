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

IMPORTANT: specs, `docs/STATUS.md`, `docs/decisions.md`, and `README.md` are updated in the same
commit as the code or decision that changes them. Never let them drift (README added by Toni,
2026-10-23).

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

## Git and worktrees

IMPORTANT: every session or task that changes files works in its own git worktree (Toni,
2026-10-23), so agents never overlap in one checkout:

- Before the first change, call `EnterWorktree` with a short task name (it branches from the
  latest `origin/main` under `.claude/worktrees/`). Never edit, build, or commit in the main
  checkout at `~/Development/latchkey`; it stays on `main`, untouched.
- In a fresh worktree, `scripts/link-local-files.sh` links the gitignored personal files from the
  main checkout (`.env`, `CLAUDE.local.md`, `macos/Config/Local.xcconfig`). The Mac Makefile,
  `package.sh`, and `deploy/deploy.sh` run it themselves; `package.sh` refuses to build without the
  signing team, because a differently signed app loses the installed app's permissions and pairing.
- Merge by fast-forward: `git fetch origin && git rebase origin/main`, then `git push origin
  HEAD:<branch>` and `git push origin HEAD:main`. If main moved meanwhile (another session),
  rebase again and retest. Never force-push (one exception, approved by Toni 2026-10-23:
  rewriting history to remove the relay's address).
- A worktree is removed the moment its work is on main (Toni, 2026-10-24): no stale copies on
  disk or branches in git. A session leaves with `ExitWorktree` (`remove`) as soon as its task is
  merged; whoever merges a helper agent's branch removes that agent's worktree right away
  (`git worktree unlock <path>`, `git worktree remove <path>`, `git branch -d <branch>`: Claude
  Code keeps it locked while the session runs, and never resumes a helper after its branch is on
  main; start a new one). Leaving with `keep` and waiting for a script is not the way (it left a
  helper's copy behind on 2026-10-25). Two checks enforce it: `scripts/tidy.sh` (after every push
  and at every session start) removes any worktree that is merged, clean, and not held by a live
  session, and a helper's worktree even while its session runs once its commits are on main and
  no program is running in it; `scripts/loose-ends.sh` names any finished helper worktree still
  on disk before a turn can end. Only a copy with no commits of its own waits an hour, since a
  helper agent may still be starting in it. `ExitWorktree` (`remove`) refuses whenever the session
  made commits, even when they are already on GitHub's main (it counts from where the branch
  started). So before leaving: check that nothing is uncommitted and that `git merge-base
  --is-ancestor HEAD refs/remotes/origin/main` succeeds, then call it with `discard_changes: true`.
  That check is the only thing that makes the override safe; without it, never use it.
- Stage files by name, never `git add -A` or `git add .` (unfinished work of others was committed
  that way on 2026-10-23). Never stash (the stash is shared between worktrees; see below).
- Private remote `github.com/tonimelisma/latchkey`, default branch `main`. Small commits. Open
  PRs only when asked.

## Every increment ships (Toni, 2026-10-23)

IMPORTANT: every working increment, however small, is published and installed. In order:

1. Tests and lint pass for what changed (`make test` / `make lint` in `relay/` and `macos/`).
2. Bump the app's patch version (`MARKETING_VERSION` in `macos/project.yml`) when anything in the
   Mac app changed.
3. Update specs, `docs/STATUS.md`, `docs/decisions.md`, and `README.md` in the same commit.
4. Commit (files by name) and fast-forward `main` (above).
5. If `relay/` changed: `deploy/deploy.sh`.
6. If `macos/` changed: `make -C macos install` builds the disk image, quits the running app
   cleanly, replaces `/Applications/Latchkey.app`, starts it, and checks it reports the new
   version (pairing and permissions carry over). Toni never installs by hand.
7. If behavior changed: a live check through the hosted relay with a fresh Claude Code session
   (`claude -p --allowedTools mcp__claude_ai_Latchkey`); this session's own connector keeps the
   tool list it started with.

## Nothing left behind (Toni, 2026-10-23 and 2026-10-24)

IMPORTANT: Toni never hears about loose branches, stashes, or leftovers, and never asks for a
cleanup. No work is ever lost. At the end of every turn:

- Finished work is merged into `main` and pushed to GitHub.
- Unfinished work is committed and pushed to its own branch (WIP commits are fine), and the reply
  says in a line what is still open. Nothing lives only on this Mac.
- Leftovers found from earlier sessions (unmerged branches, stashes, abandoned worktrees, Dependabot
  updates) are integrated: tested and merged into main if they work, otherwise reported to Toni
  with what they contain. Delete a branch or stash only after its work is on main.
- No stashes at all: set work aside with a commit on your branch.

Enforced by hooks in `.claude/settings.json` (`scripts/hooks.sh`):
- `scripts/loose-ends.sh` lists anything not safely on main: this worktree's uncommitted,
  unpushed, or unmerged work; stashes; branches (local or GitHub) not on main and not checked out
  anywhere; unpushed branches; worktrees with uncommitted work untouched for a day; the main
  checkout off `main` or dirty. It runs when a session starts (Claude is told) and before Claude
  ends a turn (Claude is sent back once to resolve it).
- Commands that can lose work are refused: `git stash` in any spelling (only `list` and `show`
  are allowed), force-push (`-f`, `--force…`, or a `+refspec`), `git reset --hard`,
  `git clean -f`, `git branch -D`, `git checkout -- .`. A `git push` is also refused while
  `scripts/private-values-check.sh` finds one of the deployment's private values in a tracked
  file or any commit. Without `jq`, every command that mentions git is refused. Delete merged branches
  with `git branch -d`; never remove a worktree with `discard_changes` unless its commits are on
  main.
- After every push and at every session start, `scripts/tidy.sh` runs automatically (Claude Code
  hook in `.claude/settings.json`): branches merged into main (local and GitHub; never main, the
  current branch, or a branch checked out in a worktree), finished worktrees (as soon as merged),
  stale refs, every disk image except the one for the version in `macos/project.yml`, built apps
  under `macos/build/DerivedData/Build/Products` (in the main checkout and in removed worktrees),
  and all but the newest relay Docker image. Last, it fast-forwards the main checkout when it is
  on `main`, clean, and only behind. Run it by hand after a push made outside Claude Code.
- Delete temporary files (scratch scripts, copies of databases, old app copies, servers' `/tmp`
  files) as soon as the task that needed them is done; scratchpad folders end empty.
- Never commit the hosted relay's address, its server details, or the Apple team ID; they live in
  the gitignored `.env`, `macos/Config/Local.xcconfig`, and `CLAUDE.local.md` (Toni, 2026-10-23).

## Gotchas

- `~/Development/Relay` is an unrelated project. This repo is `~/Development/latchkey`.
- The relay must never wait on the Mac without a deadline (Constitution II).
- A capability the user turned off must not appear to Claude at all (Constitution III).
- A relay test or local check that registers its own client must set
  `AllowedClients: oauth.AnyClientHost()`; the default accepts only clients on claude.ai, and
  `/register` answers 403.
- Never start a relay version from before the key file (2026-10-25) on a database a newer one
  has opened: it can't read the encrypted keys. `deploy.sh` handles this for the first deploy only.
- Changing the text of `relay/internal/account/templates/terms.html` or `privacy.html` means
  changing `LegalEffectiveDate` in `relay/internal/account/legal.go`. A new table needs a row in
  `data-model.md` and a phrase in the privacy policy (a test fails otherwise).

## Commands

Relay (run in `relay/`):
- `make test`: all tests, with the race detector (includes a headless-Chrome test; skipped if
  Chrome is missing)
- `make test-short`: the same without the browser test
- `make claude-check`: real Claude Code against a private relay and the pretend Mac
- `make lint`: golangci-lint (pinned in the Makefile) with gofumpt; must report 0 issues
- `make fmt`: format
- `make run`: run locally with development defaults (data in `relay/.data/`)
- `make security`: every security check (known vulnerabilities, committed secrets and private
  values, Semgrep, ShellCheck, tidy modules); the deploy runs it first
- `make script-tests`: tests of the deploy and repository scripts (no server, no network)

- `make mac-check`: the Mac app's real connection code against a private relay (battery vs
  pmset, tool off, silent network cut, reconnect)

Hosted relay: `deploy/deploy.sh` deploys to the host and Google Cloud VM named in the gitignored
`.env` (see the script's header), behind that VM's Caddy; needs `CLOUDFLARE_API_TOKEN` and `RESEND_API_KEY`
(send-only) in the gitignored `.env`, plus `RESEND_ADMIN_KEY` (full access) for the first run that
sets up the sending domain (removed from `.env` 2026-10-25, once the domain was verified).
It deploys only a clean checkout at origin/main, and goes back to the previous version if the new
relay doesn't answer. `.env` may also hold `OPERATOR_NAME`, `OPERATOR_CONTACT`, `OPERATOR_LAW`,
`OPERATOR_PROVIDERS`, and `BACKUP_DAYS` (free text in single quotes): they switch on the relay's
terms and privacy pages. `deploy/backup-schedule.sh` turns on the nightly copy of the server's
disk (kept 14 days).
Operator commands run inside the relay's container: `docker exec latchkey-relay /relay account
list | account suspend <email> [reason] | account unsuspend <email> | account delete <email> |
block <email> [reason] | unblock <email> | block list`; `relay reset-keys --confirm` (relay
stopped) deletes the stored keys when the key file is lost. Any other argument prints the list
and exits 2; no arguments starts the server.

Mac app (run in `macos/`; `project.yml` is the source, the `.xcodeproj` is generated):
- `make test`: unit and contract tests (Swift Testing); exit code is the result
- `make lint` / `make fmt`: swift-format
- `make build` / `make run`: build, or build and open the app
- `make dmg`: the installable disk image, `build/Latchkey-<version>.dmg`
- `make install`: the disk image, installed into /Applications and started (every increment)
- Signing: copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set your team ID

<!-- Maintainers: keep this file under ~100 lines. Status and decisions live in docs/, topic
knowledge in .claude/rules/, multi-step procedures in docs/. Test each line: would removing it
cause Claude to make mistakes? -->
