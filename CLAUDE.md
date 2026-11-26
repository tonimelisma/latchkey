# Latchkey

Your Mac, at Claude's fingertips from anywhere: a Swift menu bar app keeps an outbound WebSocket
to a Go relay, the MCP server Claude connects to as a custom connector (offline answers when the
Mac is away). A Go program does the same for Linux servers. Free, open source, self-hostable;
Apple silicon, current + previous macOS. Owner: Toni Melisma (`tonimelisma`).

At the start of every session:
1. Read `docs/STATUS.md` (current phase, next steps, open questions), then the spec folder you
   work in.
2. List open problem reports: `go run ./cmd/latchkey-reports list` in `relay/` (spec 014). Ask
   Toni once per report (AskUserQuestion, its summary in a few words): look into it here, in a
   separate session (`create_session`), or later; add its id to "Problem reports asked about" in
   `docs/STATUS.md`. Reports already asked about get one line, no question.

Why each rule exists, with Toni's words and dates: `docs/decisions.md`.

## Two ways to work (spec 016)

Which one a session is depends on where it runs; everything else here applies to both.

- **Cloud session** (the main way; `CLAUDE_CODE_REMOTE=true`, an Ubuntu VM, no macOS): follows
  `docs/cloud-sessions.md`. No Mac: GitHub's Mac runner builds and tests the Mac app. It never
  uses Latchkey to reach Toni's MacBook while developing (builds, tests, the updater,
  screenshots), except a live check Toni asks for in that session.
- **Local session** (Claude Code Toni started on his Mac; its own worktree): builds and tests
  natively (`make test`, `make lint` in `macos/`), and after building the Mac app runs `make -C
  macos sandbox` (spec 016) before calling the change done. It reads the running Latchkey
  directly: its version (`defaults read /Applications/Latchkey.app/Contents/Info
  CFBundleShortVersionString`), macOS's log (`log show --last 1h --info --predicate 'subsystem
  == "net.melisma.latchkey"'`; notice lines last only hours), crash reports
  (`~/Library/Logs/DiagnosticReports/Latchkey*`); its tool list and activity log through the
  Latchkey connector (`machines`, `latchkey_log`; each call counts as use and delays an update's
  install by 10 minutes). Never `make -C macos install` while Toni may be using Latchkey (it
  quits it).

## Done means Toni's conditions

For any request about whether Latchkey works somewhere (a capability, a site or app, a screen
state); docs and process work just say what changed and what was checked.

- Before starting, write Toni's exact conditions as rows, in his words, plus the spec's success
  criteria: screen state (unlocked / locked / lid closed), browser (Safari tab / Latchkey's own),
  fresh vs already signed in, the site or app. Each row is its own work-list item; the first
  reply lists the rows and how each will be checked.
- A row is VERIFIED only by a real run in that exact condition with the installed version,
  quoted with version, time, and the result seen (the page, the database), not Claude's words.
  Unit tests, a run in another screen state, or reasoning from code verify nothing.
- No test sessions against Toni's real data except a live check he asks for. A run on GitHub's
  runners or a test Mac is evidence only for the conditions it has (unlocked, own browser, served
  pages, test data); locked, lid closed, real iMessage, real sites and his accounts stay NOT
  VERIFIED until he runs them; say so.
- Every answer to "can you / does it / is it working" leads with the rows, like "Locked, fresh
  sign-in: NOT VERIFIED (scheduled for the next lock) | Unlocked: VERIFIED 0.8.218 10:17". Never
  "done", "works", or "should work" for a row that isn't verified.
- After two fixes that didn't work for the same row, stop and say so, with what was learned,
  rather than a third patch.

## Working with Toni

- Plain, short language. Lead with the answer. Explain unavoidable jargon in a few words.
- Never use internal labels (M1, T015, requirement IDs, `make run`) without saying in words
  what they are; questions must make sense to someone who hasn't read the plan.
- No manual work for Toni: Claude runs every test and check itself, scripted. Ask only for what
  only Toni can do (his accounts, devices, approvals), keep it minimal, and say so up front.
- Complete solutions, not partial matches. Say plainly when something falls short.
- Never end a turn while an item Toni asked for can still move forward without him. When one is
  blocked, go on to the next; prepare each blocked step as a single action for him and list
  those steps together at the end.
- Live tests that write to Toni's apps remove what they made in their own teardown, even when
  they fail, and confirm the removal.

## Toni decides

Toni makes every product and engineering choice. Claude proposes; Toni picks. Ask only for a
real choice he hasn't made yet; never ask for a go-ahead, or how or in which order to do what
is already chosen, and never end a turn with a go-ahead question.

- Wording and visual design users see: Claude drafts it against Apple's Human Interface
  Guidelines and usability guidance, and never asks.
- Ask about: features and behavior users see, libraries and tools, architecture, repository
  layout, protocol or schema shape, milestone and task order, test approach, temporary
  workarounds, user-facing defaults. Never make one of these silently.
- Don't ask about low-level details (encodings, internal names, private helpers, file names
  inside a package): weigh two or three options, pick one, and record options, pros and cons and
  the choice in `research.md` or the contract.
- Anything not settled in a spec, plan, or `docs/decisions.md` is undecided: ask before acting
  on it, never write it into a doc as settled. Don't re-ask what `docs/decisions.md` records.
- Ask with AskUserQuestion: multiple choice, recommended option first with a one-line why, up to
  4 related questions per call, all of a task's questions before starting its work.
- Record each answer in the spec or plan and in `docs/decisions.md`, in the same commit.

## Development process (spec-driven)

- Source of truth: `memory/constitution.md` (change only with Toni's approval), then
  `specs/NNN-name/` (`spec.md`, `plan.md`, `research.md`, `contracts/`, `tasks.md`), which win
  over every other doc.
- "Next step", "continue" or similar: take the first item under "Next steps" in
  `docs/STATUS.md`, do it by this process, verify it ("Done means Toni's conditions"), update
  STATUS (mark it done, write the new next steps), commit, and report in plain language.

1. Specify what and why in `spec.md`, no technology. Requirements in EARS form ("When X, the
   system shall Y") with stable IDs: never renumber; mark removed ones "withdrawn". Mark anything
   undecided `[NEEDS CLARIFICATION: ...]`; never guess.
2. Plan the how in `plan.md`; every decision names the requirements it serves; end with the
   constitution check. Before a plan, contract or task list is done, check it holds together:
   every requirement has a mechanism and, across the relay–Mac boundary, a message in the
   contracts; no two docs contradict; milestone order matches the dependencies. Fix gaps that
   follow from the spec; ask Toni only where the spec leaves a real choice.
3. A tool reports, Claude judges (Constitution X, `.claude/rules/tool-design.md`): a requirement
   that has a tool decide what a page or app state means is raised with Toni before planning.
4. Break into `tasks.md`; each task testable, parallel-safe ones marked `[P]`.
5. Implement test-first: contract and integration tests written and seen failing first.
   Integration tests use a real MCP client, not mocks.
6. New work gets its own `specs/NNN-name/`, starting with research (existing MCP servers, macOS
   APIs, permissions, risks) and an interview of Toni; stop for his review before tasks or code.

Specs, `docs/STATUS.md`, `docs/decisions.md` and `README.md` change in the same commit as the
code or decision that changes them. The README says in plain words what each capability lets
Claude do and not do, and what works when (locked, unlocked, the never-disturb rule).

## Git

`main` takes changes only through a pull request whose checks passed (a ruleset).

- One session, one branch, one pull request. Work on the session's branch (or one named for the
  task), push early and often, and open its pull request at the first commit (a draft while
  unfinished), so other sessions see what is taken.
- A pull request's branch is never replaced: fixes, review changes and main go onto it as new
  commits (`git fetch origin && git merge origin/main`, or GitHub's "Update branch"); never
  rebase a pushed branch, never close a pull request to redo it elsewhere, never force-push.
- Merge by squash: once the pull request is ready, turn on auto-merge (`enable_pr_auto_merge`,
  method squash).
- Branches are deleted by GitHub (merged) or `branch-cleanup.yml` (closed), never by hand or
  through Latchkey on the Mac.
- Stage files by name, never `git add -A` or `git add .`. Never stash: set work aside with a
  commit on your branch.
- A local session never works in the main checkout `~/Development/latchkey` (it stays on
  `main`): `EnterWorktree`, `scripts/link-local-files.sh`, leaving once merged:
  `docs/git-worktrees.md`.

## Every finished batch ships

A batch is the fixes for one request: per fix run the targeted tests, then the full checks once
per batch, then:

1. Tests and lint pass for what changed. A diff in `macos/App/SignIn/`, `Browser/`, `Messages/`
   or `Mail/` gets a security review by a review subagent before commit, its findings fixed or
   answered in the same commit.
2. Never write a version number by hand: releases are tags made by CI (`scripts/release-tag.sh`,
   the highest tag + 1): `mac-<x.y.z>`, `linux-<x.y.z>`. A tagged commit keeps its number.
3. Specs, STATUS, decisions and README in the same commit; commit files by name; merge (above).
4. Merging ships: the workflows (`docs/cloud-sessions.md`, "Releases") test, tag, sign and
   publish what changed; installed Macs and Linux servers update themselves (a Mac only after 10
   minutes without a tool call). Toni never installs by hand. Watch the runs (`gh api
   repos/tonimelisma/latchkey/actions/runs`) until the release job ends.

## Nothing left behind

No work is ever lost, and Toni never hears about leftovers. At the end of every turn:

- Finished work is merged into `main`; unfinished work is committed and pushed to its branch
  (WIP commits are fine) and the reply says in a line what is still open.
- Leftovers (branches nobody has pushed to for 3 days, abandoned worktrees, Dependabot updates)
  are tested and merged if they work, otherwise reported to Toni with what they contain. Another
  session's live branch is never touched.
- Temporary files (scratch scripts, database copies, old app copies, servers' `/tmp` files) are
  deleted when their task is done; scratchpad folders end empty.
- Never commit a working relay's address or the Apple team ID: only placeholders such as
  `relay.example.com`; the real values live in the gitignored `macos/Config/Local.xcconfig` and
  `CLAUDE.local.md`.

Hooks enforce this (`docs/hooks.md`): loose ends listed at session start; the work list
`~/.claude/worklists/<session id>.md` (`- [ ]` open, `- [x]` done and verified, `- [toni]` only
Toni) keeps a turn going; commands that lose work and pushes with a private value are refused.

## Every issue becomes a regression test

Every issue found (by Toni, a problem report, a review, a test, one caught before merge) gets,
in its fix's commit, an automated test that fails without the fix, in the lowest test layer that
reproduces it (spec 016). A problem report or a new eval failure (`latchkey-reports evals`)
looked into is an issue found; report contents never go into the repository, a pull request or
a CI log; once fixed on main or Toni has heard why not, `latchkey-reports delete <id>`.

## Whatever doesn't work is a bug in Latchkey

It is Latchkey's bug, never the site's, the app's, macOS's or the user's, and never "bot
protection" or a CAPTCHA: find what Latchkey does differently from Safari (view, cookies and
storage, window and screen, the events a click or key sends, timing) and fix it. Until then it is
an open bug, with what was learned, in reports, rows, STATUS and tests.

## Never disturb the user (Constitution IV)

While unlocked, someone may be using any app: Latchkey never brings a window to the front,
drives an app's window (selection, view, text), moves the pointer or types into their apps.
Background work they can't see is fine (scripting, databases, Latchkey's off-screen browser). A
feature that needs the front or another app's window is not built, even with a guard. Exceptions
Toni chose: computer control, the user's own Safari tabs, the shell's `open`.

## Gotchas

- `~/Development/Relay` is an unrelated project. This repo is `~/Development/latchkey`.
- The relay never waits on the Mac without a deadline (Constitution II).
- A capability the user turned off never appears to Claude (Constitution III).
- Relay gotchas (test clients, the key file, legal pages): `.claude/rules/relay.md`.
- One-time setup only Toni does (secrets, package access): `docs/development.md`, "Owner setup".

## Commands

`make test`, `make lint` (0 issues) in `relay/`, `macos/`, `linux/`; `make security` and `make
script-tests` in `relay/`. Everything else: `docs/commands.md`.

<!-- Maintainers: keep this file under ~200 lines (Anthropic's guidance for CLAUDE.md). Status and
decisions live in docs/, topic knowledge in .claude/rules/, procedures in docs/. A rule that must
always hold belongs in a hook or a test, not here. Test each line: would removing it cause Claude
to make mistakes? -->
