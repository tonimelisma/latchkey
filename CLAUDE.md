# CLAUDE.md

## What this is

Latchkey puts a person's Mac, and their Linux servers, at Claude's fingertips from anywhere: a
Swift menu bar app (and a Go program on Linux) keeps an outbound WebSocket to a Go relay, which is
the MCP server Claude connects to as a custom connector and answers for a machine that is away.
Free, open source, self-hostable; Apple silicon, the current and previous macOS. It ships as a
signed Mac app with Sparkle updates, a signed Linux binary, and a signed relay container image.

## Working style

- When it is clear what is wanted, do it. Ask only for what only the user can do, or for a real
  product choice nobody has made yet.
- Don't end a turn with a summary announcing the next step, an offer to continue, or a list of
  decisions that block nothing: take the next step.
- Stop only when nothing can move forward without the user, or when what blocks you is
  deliberately protected (a permission, a ruleset, a secret). Then say exactly what is needed.
- Still confirm destructive or irreversible actions outside the normal flow (deleting data,
  rewriting history, changing settings); the normal flow (branch, commit, PR, merge, release) is
  not one of them.
- Live tests clean up everything they create in their own teardown, even when they fail, and
  confirm the removal.
- A product choice nobody has made yet (behavior or wording users see, a library, a protocol or
  schema shape, a default) goes to the maintainer as a question, and the answer gets an ADR.
  Wording and visual design follow Apple's Human Interface Guidelines without asking.

## Product invariants

- A paired machine never accepts inbound connections: it only dials out to the relay.
  ([ADR 0001](docs/adr/0001-constitution.md) I, [ADR 0002](docs/adr/0002-nat-traversal-the-mac-app-keeps-one-outbound-websocket-to.md))
- Fail fast, never hang: every call from Claude is answered within a bounded time, and the relay
  never waits on a machine without a deadline. ([ADR 0001](docs/adr/0001-constitution.md) II, [ADR 0004](docs/adr/0004-deadlines.md))
- Disabled means nonexistent: a capability the user turned off is never listed, callable or
  mentioned to Claude. ([ADR 0001](docs/adr/0001-constitution.md) III)
- Never disturb the user: while the Mac is unlocked, Latchkey never brings a window to the front,
  drives an app's window (selection, view, text), moves the pointer or types into the user's
  apps. Background work they can't see is fine (scripting, databases, Latchkey's off-screen
  browser). A feature that needs the front or another app's window is not built, even with a
  guard. The exceptions the user asks for knowingly: computer control, the user's own Safari
  tabs, the shell's `open`. ([ADR 0001](docs/adr/0001-constitution.md) IV)
- Self-hostable: the relay is one Go binary and one SQLite file in a Docker image, and the hosted
  relay runs exactly that code. ([ADR 0001](docs/adr/0001-constitution.md) V, [ADR 0011](docs/adr/0011-relay-implementation.md))
- Store the minimum: tool arguments and results never go into the relay's database; what it
  stores is listed in `docs/design/data-model.md`. ([ADR 0001](docs/adr/0001-constitution.md) VI)
- A tool reports; Claude judges: a tool does the one action Claude names and says what it did and
  the state as it is; it never decides what a page or app state means, retries, or waits for
  content on its own (`.claude/rules/tool-design.md`). ([ADR 0001](docs/adr/0001-constitution.md) X)
- The Release app's identifiers (`net.melisma.latchkey`, its helper, the `latchkey` scheme)
  never change: installed copies keep their pairing, permissions and settings under them
  (`.claude/rules/macos.md`). ([ADR 0010](docs/adr/0010-mac-app-packaging.md))

## Engineering philosophy

- No compatibility shims. When a structure is wrong, replace it and migrate its callers in the
  same change.
- The smallest correct design. Simplicity first; measure before optimizing, never optimize on a
  hunch.
- One owner per fact, per mutation and per side effect. Two places that know the same thing will
  disagree.
- Abstractions only at real boundaries (a process, a network, a storage format, a platform), not
  in anticipation.
- Don't guess and don't fabricate: an unknown API, path, value or result is looked up, measured or
  reported as unknown.
- You own the repository. Nothing is "pre-existing" or someone else's problem, and red CI is never
  waived: it is fixed first.
- Comments and docs describe current behavior and why it is that way, never its history.
- Whatever doesn't work is a bug in Latchkey: never the site's, the app's, macOS's or the user's,
  and never "bot protection" or a CAPTCHA. Find what Latchkey does differently from Safari (view,
  cookies and storage, window and screen, the events a click or key sends, timing) and fix it;
  until then it is an open issue with what was learned.

## Engineering practices

- Test first. A change in behavior starts with a test that fails without it. Contract and
  integration tests use a real MCP client, not mocks of one.
- Every bug, CI failure and review finding gets a regression test, seen failing before the fix;
  quote its red output in the PR. Every issue found (a problem report, a review, a test, a new
  eval failure) gets its test in the lowest layer that reproduces it (fast, integration, or the
  sandbox Mac; `docs/regression-coverage.md` gets its row).
- The instrumentation flywheel, every increment:
  - Never guess a bug's cause. If the logs and metrics can't explain it, add the instrumentation
    first, so this occurrence or the next one is diagnosable, then fix.
  - Never guess at performance: measure, keep a baseline, optimize, and report before and after.
  - Even when nothing is blocked, review the instrumentation on every path you touched: add what
    was missing, remove what is noise.
- Tests are hermetic: temporary directories and fixtures, never the developer's real data, config
  or accounts.
- A diff in `macos/App/SignIn/`, `Browser/`, `Messages/` or `Mail/` gets a security review by a
  review subagent before commit (`.claude/rules/secrets-and-pages.md`), its findings fixed or
  answered in the same commit.
- Done means the requester's conditions. For a request about whether Latchkey works somewhere (a
  capability, a site or app, a screen state), write the requester's exact conditions as rows
  first: screen state (unlocked, locked, lid closed), browser (a Safari tab or Latchkey's own),
  fresh or signed in, the site or app. A row is verified only by a real run in exactly that
  condition with the installed version, quoted with version, time and what was seen. A run on
  GitHub's runners or the sandbox Mac is evidence only for the conditions it has (unlocked, test
  data); rows that need real accounts, a locked Mac or a closed lid stay unverified until the
  requester runs them, and the answer says so. After two fixes that didn't work for one row,
  stop and report what was learned.
- Problem reports (spec 014): `go run ./cmd/latchkey-reports list` in `relay/` lists the open
  ones. Each one looked into is an issue found; report contents never go into the repository, a
  PR or a CI log; once fixed on main, or answered, `latchkey-reports delete <id>`.
- Go: `make lint` reports 0 issues (golangci-lint with gofumpt). Swift: `make lint` (swift
  format, strict). `macos/project.yml` is the Xcode project's source; never edit the generated
  project. Path-specific rules: `.claude/rules/` (macOS, relay, connectors, tool design, secrets).

## Commands

```sh
script/verify                  # everything CI checks that runs on Linux, in one command (before every push)
make -C relay test             # relay: every test, race detector, headless Chrome
make -C relay lint             # relay: golangci-lint, 0 issues
make -C relay security         # relay: vulnerabilities, committed secrets, Semgrep, ShellCheck, tidy modules
make -C relay script-tests     # the repository scripts' tests
make -C linux test lint        # the Linux program
make -C macos test lint        # the Mac app (macOS only)
cd macos && xcodebuild -project Latchkey.xcodeproj -scheme Latchkey -destination 'platform=macOS' test -only-testing:LatchkeyTests/FilesTests   # one Swift suite
cd relay && go test ./internal/hub -run TestName   # one Go test
make -C relay fmt              # format Go; make -C macos fmt for Swift
script/process-check           # requirements, tests and doc links agree
script/stage start | pre-merge <PR> | post-merge <PR>
```

Everything else (end-to-end checks, the sandbox Mac, evals, operator commands):
`docs/commands.md`.

## Where docs live

- `docs/index.md` maps every doc. Requirements live in `docs/requirements/<capability>.md`
  (one per former spec): stable IDs (`FR-NNN`, `SC-NNN`), one EARS sentence each, current
  behavior only, each `[verified]` by a test tagged `Validates: <ID>` or `unverified: <why>`.
  Future work lives in GitHub issues, not in docs.
- `docs/design/<capability>.md` (each starts with `GOVERNS: <paths>`) says how that part is built
  and why; `docs/design/contracts/` holds the protocols and tool contracts; `docs/adr/NNNN-title.md`
  records each decision (superseded, never deleted; [index](docs/adr/README.md)); dated research
  in `docs/research/`; `docs/lessons.md` holds rules learned and open problems, and is pruned
  when they are resolved.
- New work on a capability starts with research (existing MCP servers, macOS APIs, permissions,
  risks) in `docs/research/`, then requirements (mark anything undecided and ask, never guess),
  then the design and its ADRs, checked against the constitution; then tests, then code. Across
  the relay–Mac boundary every requirement has a message in the contracts.
- The README says in plain words what each capability lets Claude do and not do, and what works
  when (locked, unlocked, never disturbing the user).
- Update the docs and this file in the same PR as the code they describe.

## Two ways to work

- **Cloud session** (the default; `CLAUDE_CODE_REMOTE=true`, an Ubuntu VM): CI is the
  verification; GitHub's Mac runner builds and tests the Mac app. It never uses Latchkey to reach
  a developer's Mac while developing. Details: `docs/cloud-sessions.md`.
- **Local session** on any Mac with Latchkey installed, in its own worktree
  (`docs/git-worktrees.md`): builds and tests natively, runs `make -C macos sandbox` after
  building the Mac app, and may inspect the installed app read-only (its version, macOS's log for
  `net.melisma.latchkey`, crash reports). Never `make -C macos install` while the installed app
  is in use (it quits it).
- Either way, live checks on real accounts or data run only when the person running the session
  asks for them.

## Increment lifecycle

1. **Start**: `script/stage start`. Anything red on main or in the last scheduled run, and any
   unanswered review comment on recent PRs, is fixed before new work. Read the open issues and
   the open problem reports.
2. **Ready**: write the Definition of Ready in the PR body: the problem, requirement IDs or
   issue, acceptance criteria, what is out of scope.
3. **Test first**, then implement with the instrumentation flywheel.
4. **Verify** with the one verify command; it must be green before pushing.
5. **Docs** (requirements, design, ADRs, lessons, this file) in the same PR.
6. **Land**: PR, wait for `CI gate`, squash-merge, which releases (see Git, CI and PRs).
7. **Report**: after the merge, one PR comment with the Definition of Done checklist and the final
   increment report (below).

A plan that spans several increments lives in a GitHub tracking issue with a checklist, never in
a file. Never committed: per-PR report or readiness files, session state or resume files, ledgers
of merged PRs. That information belongs in the PR and its comments.

## Git, CI and PRs

- One branch per increment, cut from a fresh `origin/main`, named `feat/`, `fix/`, `docs/`,
  `chore/`, `refactor/` or `perf/` plus a short topic. Never reuse a branch after its PR merged;
  never name a branch for the tool that wrote it.
- Every change lands through a PR whose body fills `.github/pull_request_template.md`. CI checks
  the body, and that a PR titled `fix...` changes a test.
- `CI gate` is the one required check: a job that needs every other job. Wait for it
  (`script/stage pre-merge <PR>`), and fix every failure; never bypass it.
- Squash-merge as soon as `CI gate` is green, without asking: in a cloud session with
  `gh api -X PUT repos/<owner>/<repo>/pulls/<N>/merge -f merge_method=squash -f sha=<head sha>`
  (`script/stage post-merge <PR>` does this); locally with `gh pr merge --auto --squash`.
- Merging to main releases; nobody tags or publishes by hand.
- The cloud sessions' GitHub proxy refuses tag pushes, branch deletion and GraphQL: use the REST
  API (`gh api`), and leave branch deletion to GitHub's delete-on-merge and the branch-cleanup
  workflow.
- Commit messages: an imperative subject saying what changed; the body says why.
- A PR's branch is never replaced: fixes and main go onto it as new commits (merge
  `origin/main`, never rebase a pushed branch, never force-push, never close a PR to redo it
  elsewhere). Stage files by name, never `git add -A`; never stash: set work aside with a commit.
- CI (`.github/workflows/ci.yml`, workflow `CI`) runs on every PR, on main, daily (so a newly
  published vulnerability fails without a push) and by hand: the relay's tests, lint and security
  checks; the Linux program's; the scripts' tests and actionlint; the process checks; and the Mac
  app's build, lint and tests on four macOS runners side by side, only when `macos/` or the
  workflow changed (on main, a tree its PR already tested is only built, for the cache).
  `e2e.yml`'s end-to-end checks are reported, not required.
- Releases run after CI passes on main (`workflow_run` of `CI`, push events only;
  [ADR 0180](docs/adr/0180-releases-run-after-ci-passes-on-main.md)), each for the commit CI
  tested and only when its folder changed since its last release: `macos/` gets the tag
  `mac-<x.y.z>` (`mac-tag.yml`: built, signed, published with Sparkle's feed; installed Macs
  update after 10 minutes without a tool call); `linux/` gets `linux-<x.y.z>`
  (`linux-release.yml`: both architectures, Ed25519-signed, with `SHA256SUMS`; servers update
  within a day); `relay/` publishes `ghcr.io/tonimelisma/latchkey-relay` and the intake image,
  signed with cosign keyless by `relay-image.yml` on `refs/heads/main` (hosts verify that
  identity, so the file name and branch never change). The version is the highest tag's patch + 1 (`scripts/release-tag.sh`);
  `NEXT_VERSION=x.y.z` starts a new series. A tagged commit keeps its number.

## Privacy review

Before every commit, read your own staged diff (`git diff --cached`) and remove anything private
about the maintainer, their family or their computers: people's names, addresses, personal email
addresses and accounts, hostnames, home-directory paths, IP addresses, tenant, client or vault
IDs, real personal documents or photos. Use neutral stand-ins in tests and examples. There is no
list of private terms to check against: judge the diff. A working relay's address and the Apple
team ID never go into the repository: only placeholders such as `relay.example.com`; the real
values live in the gitignored macos/Config/Local.xcconfig.

## Definition of Done

An increment is done when every line holds; the final report marks each ✅ or ❌ with evidence:

- [ ] Start stage clean: main CI, the last scheduled run and recent review comments were green or
      fixed first.
- [ ] Tests first; the regression test's red output before the fix is quoted.
- [ ] The verify command is green, and CI is green on the final commit.
- [ ] Traceability and doc checks (`script/process-check`, `script/pr-check`) are green.
- [ ] Docs and CLAUDE.md are updated in the same PR.
- [ ] Instrumentation reviewed on touched paths: what was added, what removed, or why it is
      adequate.
- [ ] Privacy review done on every commit's staged diff.
- [ ] Every review thread is answered or resolved.
- [ ] Merged; main CI green; the release it produced is linked.
- [ ] Clean up: only main and open PRs' branches remain on the remote; the working tree is clean.

### Final increment report

One PR comment after the merge, with these parts:

1. **Done / not done**: what the increment delivered, and anything left out.
2. **Definition of Ready**: as written, and whether it held.
3. **Requirements, ADRs and docs**: IDs added, changed or retired; ADRs; docs touched.
4. **Design decisions**: each with the alternatives considered and why they lost.
5. **Verification evidence**: commands, CI run links and durations, release link.
6. **Regression test**: name and red output before the fix (or "no bug fixed").
7. **Diagnosis**: for a bug, the root cause and how it was established.
8. **Instrumentation**: added, removed, and gaps still open.
9. **Performance**: before and after numbers, or "not touched".
10. **Privacy review**: done on every commit; anything removed.
11. **Smells**: what looked wrong but was out of scope.
12. **Follow-ups**: each filed as an issue, linked.
13. **Definition of Done**: the checklist above, each line ✅ or ❌ with evidence.

## Gotchas

- Relay gotchas (test clients, the key file, legal pages): `.claude/rules/relay.md`. Claude's
  connector client: `.claude/rules/claude-connectors.md`.
- The Mac runner is slower than a Mac: about 30 tests miss their timing limits there on main
  too, so compare a branch's failed tests with main's before calling one new.
- Pushing again cancels a PR's CI run in progress: push a batch, then wait.
- One-time maintainer setup (release secrets, package access): `docs/development.md`,
  "Maintainer setup".
