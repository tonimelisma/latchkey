# Latchkey

Your Mac, at Claude's fingertips from anywhere. A native Swift menu bar app keeps an outbound
WebSocket to an always-on Go relay; the relay is the MCP server Claude connects to as a custom
connector. Claude on web, Desktop, iOS and Android can then use the Mac behind a home router, and
gets an immediate, clear answer when the Mac is offline. Free, open source, self-hostable.
Apple silicon, current + previous macOS. Owner: Toni Melisma (`tonimelisma`).

**At the start of every session, read `docs/STATUS.md`** (current phase, next step, open
questions). Then read the spec folder you are working in.

## Done means Toni's conditions (Toni, 2026-11-22)

Toni asked about ten times whether Latchkey could sign in to Citi while the Mac is locked; each
time something was fixed, checked with unit tests or one run while unlocked, and called done.
So, for every request:

- Before starting, write Toni's exact conditions as rows, in his words, plus the spec's success
  criteria: screen state (unlocked / locked / lid closed), browser (Safari tab / Latchkey's own),
  fresh vs already signed in, the site or app. Each row is its own work-list item, and the first
  reply lists the rows and how each will be checked.
- A row is VERIFIED only by a live run in that exact condition with the installed version,
  quoted with version, time, and the result seen (the page, the database), not Claude's words.
  Unit tests, a run in another screen state, or reasoning from code verify nothing.
- A row only Toni can produce (the Mac locked, the lid closed) is SCHEDULED: start
  `state-check.sh wait` for its group in the background and say so.
- Every answer to "can you / does it / is it working" leads with the rows, like "Locked, fresh
  sign-in: NOT VERIFIED (scheduled for the next lock) | Unlocked: VERIFIED 0.8.218 10:17". Never
  "done", "works", or "should work" for a row that isn't verified.
- After two fixes that didn't work for the same row, stop and say so, with what was learned,
  rather than a third patch.

## "Do the next step"

When Toni says "next step", "continue", or similar: take the first item under "Next steps" in
`docs/STATUS.md`, do it following the process below, verify it ("Done means Toni's conditions"), then update `docs/STATUS.md`
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
3b. A tool reports, Claude judges (Constitution X, `.claude/rules/tool-design.md`): a
   requirement that has a tool decide what a page or app state means is raised with Toni before
   it is planned.
4. Break into `tasks.md`; each task testable, parallel-safe ones marked `[P]`.
5. Implement test-first: contract and integration tests written and seen failing first.
   Integration tests use a real MCP client, not mocks.
6. New capabilities get their own `specs/NNN-name/` on branch `NNN-name`, one at a time, in this
   order: files, Notes + iMessage, shell, browser and computer control. Start each with research
   (existing MCP servers, macOS APIs, permissions, risks) and an interview of Toni; stop for
   Toni's review before writing tasks or code.

Specs, `docs/STATUS.md`, `docs/decisions.md`, and `README.md` are updated in the same
commit as the code or decision that changes them. Never let them drift (README added by Toni,
2026-10-23). The README always says, in plain words, what Latchkey does (each capability: what
Claude can and can't do with it) and what works when (while locked, only while unlocked, the
never-disturb rule and its exceptions); any change to a capability's tools or screen-state
behavior updates those sections (Toni, 2026-11-07). `ReadmeTests` fails when a capability isn't
named there.

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

Every session or task that changes files works in its own git worktree (Toni,
2026-10-23), so agents never overlap in one checkout (a cloud session's VM is its own checkout:
see "Cloud sessions"):

- Before the first change, call `EnterWorktree` with a short task name (it branches from the
  latest `origin/main` under `.claude/worktrees/`). Never edit, build, or commit in the main
  checkout at `~/Development/latchkey`; it stays on `main`, untouched.
- In a fresh worktree, `scripts/link-local-files.sh` links the gitignored personal files from the
  main checkout (`.env`, `CLAUDE.local.md`, `macos/Config/Local.xcconfig`). The Mac Makefile and
  `package.sh` run it themselves; `package.sh` refuses to build without the
  signing team, because a differently signed app loses the installed app's permissions and pairing.
- Merge through a pull request: `git fetch origin && git rebase origin/main`, push the branch,
  open its pull request and, once CI's checks pass, merge it with the method "rebase" (a linear
  history; from a cloud session through the REST API: `gh api repos/tonimelisma/latchkey/pulls`,
  then `gh api -X PUT …/pulls/<n>/merge -f merge_method=rebase`). GitHub deletes the merged
  branch itself; `tidy.sh` and `loose-ends.sh` know rebased work. If main moved meanwhile
  (another session), rebase again and retest. Never force-push (one exception, approved by Toni
  2026-10-23: rewriting history to remove the relay's address).
- A worktree is removed the moment its work is on main (Toni, 2026-10-24): `ExitWorktree`
  (`remove`), after checking nothing is uncommitted and `git merge-base --is-ancestor HEAD
  refs/remotes/origin/main` succeeds (only then with `discard_changes: true`). A helper agent's
  worktree is removed by whoever merges it. Details: `docs/git-worktrees.md`.
- Stage files by name, never `git add -A` or `git add .` (unfinished work of others was committed
  that way on 2026-10-23). Never stash (the stash is shared between worktrees; see below).
- Public remote `github.com/tonimelisma/latchkey` (public since 2026-10-31), default branch `main`. Small commits. Open
  PRs only when asked.

## Every finished batch ships (Toni, 2026-10-23; batches 2026-11-22)

Every finished batch of work is published and installed (Toni, 2026-11-22: "Batch + wait for
idle", after 49 installs in 36 hours). A batch is the fixes for one request; per fix run only
the targeted tests, then the full checks once per batch. In order:

1. Tests and lint pass for what changed (`make test` / `make lint` in `relay/` and `macos/`).
   Code that handles secrets, pages, Messages, Mail, or queued actions (`macos/App/SignIn/`,
   `macos/App/Browser/`, `macos/App/Messages/`, `macos/App/Mail/`) gets a security review of the
   diff by a review subagent before commit, its findings fixed or answered in the same commit
   (Toni, 2026-11-22; three such bugs were found only after install that weekend).
2. Never write a version number by hand: a release is a tag on a commit on main (`mac-<x.y.z>` for the
   Mac app, `linux-<x.y.z>` for Linux; Linux was `server-v<x.y.z>` until 0.1.4), made by CI with
   `scripts/release-tag.sh` (the highest tag + 1; GitHub refuses a taken one, so sessions never
   share a number; Toni, 2026-11-04). A commit already tagged keeps its number.
3. Update specs, `docs/STATUS.md`, `docs/decisions.md`, and `README.md` in the same commit.
4. Commit (files by name) and merge into `main` (above).
5. Merging ships (Toni, 2026-11-23: cloud-first; `docs/cloud-sessions.md`, "Releases"). Each
   releasing job runs in an approval environment (`release`, `production`):
   - `relay/` changed: `relay-image.yml` tests, publishes and signs the image; hosts that verify
     its signature pull it themselves. The hosted relay's server and its deployment live outside
     this repository (2026-11-23).
   - `linux/` changed: `linux-release.yml` tags, signs and publishes; installed servers (Toni's
     home server too, which no workflow ever reaches) update themselves within a day.
   - `macos/` changed: `mac-tag.yml` tags the commit `mac-<x.y.z>`; the Mac's updater
     (`macos/scripts/auto-update.sh`, a launchd agent) builds and installs that tag within
     15 minutes. The install waits until Latchkey has been idle (no tool call for 10 minutes,
     none running; it gives up after 30 and tries again next time; Toni, 2026-11-22, after an
     install restarted Latchkey in the middle of his Target order), quits the running app
     cleanly, replaces `/Applications/Latchkey.app`, starts it, checks it (pairing and
     permissions carry over), and publishes the disk image. Toni never installs by hand.
     Skipping the idle wait (`install-now`) only when Toni says so. Installs run one at a time,
     and only CI's newest tag is installed.
   Repository_dispatch from a session: `gh api repos/tonimelisma/latchkey/dispatches -f
   event_type=<type>` (`relay-image`, `linux-release`, `mac-tag`).
6. Watch the workflow runs (`gh api repos/tonimelisma/latchkey/actions/runs`) and, for the Mac,
   the updater's log through Latchkey (`docs/cloud-sessions.md`, "The Mac's updater").
7. If behavior changed: a live check through the hosted relay once the new version runs, from a
   session whose Latchkey connector started after it (a session keeps the tool list it started
   with): a fresh cloud session from claude.ai runs the cases itself with
   `state-check.sh prompt|record|merge` (`docs/cloud-sessions.md`, "Live checks"); on the Mac,
   `state-check.sh run <dir> <group…>` with fresh `claude -p` sessions. Check only what changed:
   the groups whose code changed, never every group by habit (Toni, 2026-11-05: a full run
   sends about six emails). A full run is for changes every tool shares (the connection, the
   relay's tool handling) and for refreshing `docs/use-cases.md` in a new screen state. The run
   counts for the acceptance rows of the screen state it ran in, no other ("Done means Toni's
   conditions").

## Nothing left behind (Toni, 2026-10-23 and 2026-10-24)

Toni never hears about loose branches, stashes, or leftovers, and never asks for a
cleanup. No work is ever lost. At the end of every turn:

- Finished work is merged into `main` and pushed to GitHub.
- Unfinished work is committed and pushed to its own branch (WIP commits are fine), and the reply
  says in a line what is still open. Nothing lives only on this Mac.
- Leftovers found from earlier sessions (unmerged branches, stashes, abandoned worktrees, Dependabot
  updates) are integrated: tested and merged into main if they work, otherwise reported to Toni
  with what they contain. Delete a branch or stash only after its work is on main.
- No stashes at all: set work aside with a commit on your branch.

Enforced by hooks (`.claude/settings.json`, `scripts/hooks.sh`; details in `docs/hooks.md`):
loose ends are listed at session start; `scripts/keep-going.sh` keeps Claude on its work list
`~/.claude/worklists/<session id>.md` (`- [ ]` open, `- [x]` done and verified, `- [toni]` only
Toni; Stop always works) and stops a turn once that claims "works" or "done" without the
acceptance rows; commands that lose work (stash, force-push, hard reset, `clean -f`,
`branch -D`) and pushes with a private value are refused; `scripts/tidy.sh` cleans merged
local branches, worktrees, and old builds after every push on the Mac (GitHub deletes merged
pull requests' branches; nothing to tidy after a cloud push).
- Delete temporary files (scratch scripts, copies of databases, old app copies, servers' `/tmp`
  files) as soon as the task that needed them is done; scratchpad folders end empty.
- Never commit a working relay's address or the Apple team ID: the repository holds only
  placeholders such as `relay.example.com` (Toni, 2026-10-23 and 2026-11-23); the real values live
  in the gitignored `macos/Config/Local.xcconfig` and `CLAUDE.local.md`. The push guard checks it.

## Every issue becomes a regression case (Toni, 2026-11-16)

Claude's own reports of what didn't work, filed through the relay's `feedback` tool, arrive as
files in `~/Library/Application Support/Latchkey/Feedback` (spec 001 FR-690 to FR-695). Pending
ones are the files directly in that folder; handled ones are in `Feedback/Handled`. At the start
of every session (Toni, 2026-11-23), list the pending reports (in a cloud session through
Latchkey's `shell_run`) and, if there are any, ask Toni with AskUserQuestion, naming each report's
summary in a few words: look into them in this session, start a separate session for them
(`create_session`, its prompt naming the report files), or leave them for now. Each report
looked into is an issue found (below): fixed in that session where it can be, with its
regression case, otherwise reported to Toni with what was learned. A report is handled once its
fix is on main or Toni has heard why not; then move it to `Feedback/Handled` (`shell_run` with
that folder in `writes`).

Every issue found in Latchkey (by Toni, an agent's feedback report, a live check, or
a test) gets a case in a regressions group of `macos/scripts/state-check/cases.json`
("regressions", or "regressions-browser", "-shell", "-computer", "-other" by area), in the same
commit as its fix: the id names it, `case` says what went wrong and when, `steps` say
how a fresh agent checks it and what counts as working. Cases never write anything they don't
remove. Run `state-check.sh run <dir> <its group>` after every fix that touches a case's area.

## Never disturb the user (Toni, 2026-11-07; Constitution IV)

IMPORTANT: while the Mac is unlocked, someone may be using any app. Latchkey never brings a
window to the front, never drives an app's window they may be using (selection, view, text),
and never moves the pointer or types into their apps. Background work that can't touch what they
see is fine (scripting or databases without a window; Latchkey's own off-screen browser). A feature that would need the front or another app's window is not built, not even
with a guard. Exceptions Toni chose: computer control, acting in the user's own Safari tabs, the
shell's `open`. Unreliable routes (WhatsApp Web) are left out. Removed for this on 2026-11-07:
Mail, WhatsApp sending, Notes' window editing, Messages' window actions, Reminders' window setters.

## Cloud sessions (claude.ai/code; 2026-11-21)

Development happens in cloud sessions (Toni, 2026-11-23); the Mac only builds and tests what
needs macOS. A cloud session (`CLAUDE_CODE_REMOTE=true`, a fresh Ubuntu VM run as root, no Swift
or macOS) follows `docs/cloud-sessions.md` (the session-start hook says so): no worktree;
releases through GitHub Actions; Mac builds and tests through
Latchkey's `shell_run`; the Mac installs releases itself; live checks with its own Latchkey tools.

## Owner setup (only Toni can do these; once)

- Repository secrets: `SERVER_SIGNING_KEY` (environment `release`).
- ghcr.io package `latchkey-relay`: Package settings → Manage Actions access → this repository
  with Write (so the image workflow can publish it).
- On the Mac, once: `macos/scripts/updater-setup.sh` from the main checkout (later installs keep
  it current).
- Cloud environment variable `LATCHKEY_CHECK_TO` (the live checks' own address).
- Optional: required reviewers on the environments `release`, `production`; a tag
  ruleset so only GitHub Actions creates `mac-*` and `linux-*` tags.

## Gotchas

- `~/Development/Relay` is an unrelated project. This repo is `~/Development/latchkey`.
- The relay must never wait on the Mac without a deadline (Constitution II).
- A capability the user turned off must not appear to Claude at all (Constitution III).
- Relay gotchas (test clients, the key file, legal pages): `.claude/rules/relay.md`.

## Commands

All commands, with details: `docs/commands.md`. The ones used every day:
- Relay (`relay/`): `make test`, `make lint` (0 issues), `make security`, `make script-tests`;
  releases and configuration through the workflows ("Every finished batch ships").
- Mac app (`macos/`): `make test`, `make lint`; installs by the Mac's updater (`make install`
  installs CI's newest tag by hand).
- Linux program (`linux/`): `make test`, `make lint`; releases by `linux-release.yml`.
- Screen states (`macos/scripts/state-check/`): `state-check.sh run|wait|report <folder outside
  the repo> [groups]` runs the use cases in `cases.json` with real Claude Code in the Mac's
  current screen state; `prompt|record|merge` for a cloud session running them itself; needs
  `LATCHKEY_CHECK_TO` (from `CLAUDE.local.md`, or the cloud environment).

<!-- Maintainers: keep this file under ~200 lines (Anthropic's guidance for CLAUDE.md). Status and
decisions live in docs/, topic knowledge in .claude/rules/, procedures in docs/. A rule that must
always hold belongs in a hook or a test, not here. Test each line: would removing it cause Claude
to make mistakes? -->
