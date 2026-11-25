# Cloud sessions (claude.ai/code; 2026-11-21, cloud-first since 2026-11-23)

All development happens in cloud sessions (Toni, 2026-11-23). The Mac is used only for what
physically needs macOS: building and testing the Mac app, and the Mac's own checks. Whatever a
cloud session's GitHub proxy refuses (tag pushes, releases, branch deletion, deploys) runs in
GitHub Actions, started by a merge to main or by repository_dispatch.

Moved from CLAUDE.md on 2026-11-22 (it keeps a pointer); the session-start hook tells a cloud
session to follow this file. Toni's standing rules for all his projects, from his personal instructions, which don't reach
cloud sessions (a local session has them already):

- When it is already clear what Toni wants, do it. Never ask whether to do it, how to do it, or
  which piece to do first, and never end a turn with a go-ahead question or "Yes, do it" button
  (Toni, 2026-11-05: "never ask me about whether or how to implement when it's already clear what
  I want!"). Ask only for what only Toni can do (his accounts, devices, approvals) or a real
  product choice he hasn't made yet.
- Never end a turn while any item Toni asked for can still move forward without him. When one
  item is blocked (the Mac locked, something only he can do), go on to the next unblocked one;
  stop only when every item is done or truly blocked, and list just the Toni-only steps at the
  end (Toni, 2026-11-07: "You promised not to stop before everything is done!! Several times").
- Live tests may write to Toni's real apps; every test removes what it made in its own teardown,
  even when it fails, and confirms the removal. Never leave test data behind.

Everything in CLAUDE.md applies, except:


A cloud session (`CLAUDE_CODE_REMOTE=true`) is a fresh Ubuntu 24.04 VM, run as root, with one
clone of this repository: no Swift, Xcode, or macOS, and no `.env`, `CLAUDE.local.md`, or
`Local.xcconfig`. Started from claude.ai/code or the phone it has Toni's connectors, Latchkey
included, so it reaches the Mac; started with `claude --cloud` it has none. Everything above
applies, except:

- No worktree: the VM's clone is the session's own. Skip `EnterWorktree`, `ExitWorktree` and
  `link-local-files.sh`. Git as in CLAUDE.md, "Git": one branch and one pull request per
  session, pushed early (the VM is reclaimed), never replaced; main merged in, never rebased
  onto; squash merges, by auto-merge once CI passes. Pull requests go through the REST API
  (`gh api repos/tonimelisma/latchkey/pulls -f head=<branch> -f base=main -f title=… -f body=…`)
  or the GitHub MCP tools (`create_pull_request`, `enable_pr_auto_merge` with method squash,
  `update_pull_request_branch` to merge main in on GitHub); GraphQL through the session's proxy
  doesn't work, so `gh pr …` fails. The proxy refuses tag pushes, release writes and branch
  deletions: releases happen in the workflows below, and branches are deleted by GitHub (merged)
  or `branch-cleanup.yml` (closed), never by a session or through Latchkey on the Mac.
- Hooks (`scripts/hooks.sh`): session start runs `scripts/cloud-setup.sh` first (jq, lsof, the
  pinned ShellCheck, uv; Go modules, the pinned Go tools and Semgrep, and test builds warm in the
  background, logged to `~/.cache/latchkey-cloud-setup.log`, done when `…log.done` exists), skips
  `tidy.sh`, and still reports loose ends. The guard is unchanged. No `tidy.sh` after a push
  (nothing to tidy: GitHub deletes merged branches). The work list for `keep-going.sh` is `~/.claude/worklists/<session id>.md` in the VM.
- Pushes are checked the same way as on the Mac: `private-values-check.sh` refuses a working
  relay's address or a signing team anywhere a push would publish, and needs no private values.
  Never put a secret (`.env`'s keys and tokens) in the environment: everyone using it can read it.
- Relay and Linux program: `make test`, `make lint` and `make script-tests` in `relay/` and
  `linux/` run here. `make security` also fetches from `semgrep.dev`, `vuln.go.dev` and
  `api.osv.dev`, which the default "Limited" network blocks; they work once those are in the
  environment's allowed domains. Docker is there for `make test-linux` and `make check`. Start a
  full `make test` once the warm-up is done (its `.done` file): the relay's timing tests are
  sensitive to a busy 4-CPU VM. On Linux, `make lint` also checks the Linux-only files the Mac
  never sees (`*_linux.go`).
- Releases run in GitHub Actions (CLAUDE.md, "Every finished batch
  ships"; actions pinned by SHA, checked by `scripts/tests/ci_tools_test.sh`). Started by a merge
  to main when their folder changed, or from here with repository_dispatch, which the proxy
  allows (`gh api repos/tonimelisma/latchkey/dispatches -f event_type=<type>`):

  | Workflow | On merge when | Dispatch type | Environment | What it does |
  |---|---|---|---|---|
  | `ci.yml` | every push | | | relay tests, lint, security; Linux tests, lint; script tests; actionlint |
  | `relay-image.yml` | `relay/` | `relay-image` | `production` | checks, then the signed image; hosts that verify the signature pull it |
  | `linux-release.yml` | `linux/` | `linux-release` | `release` | tag `linux-<x.y.z>`, signed release; servers update within a day |
  | `mac-tag.yml` | `macos/` | `mac-tag` | `release` | tag `mac-<x.y.z>`; the Mac's updater installs it |
  | `branch-cleanup.yml` | a pull request closes; daily | `branch-cleanup` | `branches` | deletes branches whose pull request is closed (`scripts/branch-cleanup.sh`) |

  Follow a run with `gh api repos/tonimelisma/latchkey/actions/runs?per_page=5` and its jobs'
  logs; the logs are public, so nothing the scripts print may be private (they hide the
  values they read with `::add-mask::`, and the secrets are hidden by GitHub). No workflow and no
  identity ever reaches an installed Linux server: it only pulls signed Linux releases.
  Secrets are the owner's (CLAUDE.md, "Owner setup"); a session never handles a secret's value.
- The hosted relay's server (it also runs the feedback intake; run outside this repository):
  anything that happens there is done by that server's own agent, never by a session here or
  through Latchkey's shell (Toni, 2026-11-23). A session that needs something there writes a self-contained prompt for Toni to
  give that agent: the goal, the current state, the rules (no interruption, nothing secret
  written in public), what to check, and what to report back.
- Mac app without the Mac: `mac-build.yml` lints and builds the app (gating) and runs the whole
  unit test suite (reported, not gating) on GitHub's macOS runner for every change to `macos/`
  (2026-11-23). A run takes about 9 minutes (5 of them the build) plus any wait
  for a free Mac runner; since 2026-11-25 both Mac jobs keep Xcode's compilation cache between
  runs (`actions/cache`, saved by every run, main's reused by pull requests), so a build compiles
  only what changed (Toni: "isn't there a way to cut the 40 minutes to 5 minutes?"). Pushing
  again cancels the run in progress: push a batch, then wait. The runner is macOS 26 and slower: about 30 tests miss their timing limits there
  on main too, so compare a branch's failed tests (printed with why, and any crash report) with
  main's. There, work behind a deadline can wait longer than the deadline just for a thread (a
  stand-in read 21 to 31 s late, 2026-11-24), so a test sets such a limit long unless the limit
  is what it checks (`CodeFinder.readLimit`).
- Problem reports (spec 014): `go run ./cmd/latchkey-reports list` in `relay/` lists the open
  reports at the intake (`latchkey-feedback.melisma.net`) and opens them;
  `latchkey-reports show <id>` writes one report as files (each call, its pictures, each page's
  source and record, the logs) into a new folder under `$TMPDIR`, never the repository, for
  reading with the file tools; `latchkey-reports delete <id>` deletes a dispositioned one. It needs the developer's private
  key in `LATCHKEY_REPORTS_KEY` (a variable of Toni's personal cloud environment, set by Toni)
  and the intake's token, which the session's network proxy adds for that host once Toni saved it
  as a network secret (`request_credential`). Report contents stay in the session's output.
- End to end and evals (spec 015): every pull request runs `e2e.yml`. Its `e2e-linux` and
  `e2e-mac` jobs run the checks the changed files select (`relay/e2e/capabilities.json`) with a
  real MCP client through a private relay, and compare every tool with `relay/e2e/toolsnaps`. A
  snapshot that differs fails the job: when the change is meant, download the job's artifact
  `toolsnaps-<kind>` (`gh api repos/tonimelisma/latchkey/actions/runs/<id>/artifacts`) and commit
  its files in the same pull request. Docker Hub refuses this VM's pulls (rate limit), so the
  Linux check runs on GitHub, not here. Test Mac results someone sent (`weekly-eval.sh --send`,
  started by hand; there is no weekly run or reminder, Toni 2026-11-25) are read with `go run
  ./cmd/latchkey-reports evals`.
- Mac app: build and test on the Mac through Latchkey's `shell_run` (Toni's MacBook in
  `machines`), from the pushed branch in the command's scratch folder (deleted or moved to the
  Trash when it ends), with `uses: ["open"]` (the tests run in an app; spec 004 FR-335):
  `set -o pipefail; cd "$LATCHKEY_SCRATCH" && git clone -q --depth 1 --branch <branch>
  https://github.com/tonimelisma/latchkey.git lk && cd lk/macos && xcodegen generate --quiet &&
  xcodebuild -project Latchkey.xcodeproj -scheme Latchkey -destination 'platform=macOS'
  -derivedDataPath "$LATCHKEY_SCRATCH/dd" test -quiet 2>&1 | tail -40; rm -rf "$LATCHKEY_SCRATCH/lk"
  "$LATCHKEY_SCRATCH/dd"` (the clone and build go, so nothing fills the Trash), then `shell_check` the
  job until it ends (`build` instead of `test` to only build). A pass prints `** TEST BUILD
  SUCCEEDED **` (the build, fenced) and `** TEST EXECUTE SUCCEEDED **` (the tests, outside the
  fence), not `** TEST SUCCEEDED **`; a scratch folder over 100 MB is deleted at the end, so keep
  a log you need in Downloads and delete it after. Lint the same way with
  `swift format lint --strict -r App Shared Helper Tests` in `macos/`. This tests the app
  signed ad hoc (no `Local.xcconfig` there); the Mac's updater makes the signed build when it
  installs.
  Never run `make -C macos install` through Latchkey: it quits Latchkey, which stops the command
  mid-install (spec 004 FR-309). The Mac's updater installs instead (below).
- The Mac's updater, until Sparkle updates the installed app (CLAUDE.md, "Every finished batch
  ships"; spec 001 FR-072) (`macos/scripts/auto-update.sh`; launchd agent `net.melisma.latchkey.updater`,
  set up by `macos/scripts/updater-setup.sh`): every 15 minutes it installs the newest
  `mac-<x.y.z>` tag on main when that isn't the installed version, from its own clone in
  `~/Library/Caches/net.melisma.latchkey.updater`, signed with the main checkout's
  Local.xcconfig, after Latchkey has been idle for 10 minutes. launchd, not Latchkey, is its
  parent, so the install quitting Latchkey doesn't stop it. Through Latchkey's `shell_run`
  (Shell can't run launchctl, but it can write a declared file):
  - start it now: `mkdir -p ~/Library/Caches/net.melisma.latchkey.updater/requests && touch
    ~/Library/Caches/net.melisma.latchkey.updater/requests/now`, with `writes` declaring that
    folder ("start Latchkey's updater"); `install-now` instead of `now` skips the idle wait, only
    when Toni says so;
  - see what it did: `sh ~/Library/Caches/net.melisma.latchkey.updater/auto-update.sh status`
    (installed version, newest release, last failure, the log's end; the whole log is
    `~/Library/Logs/Latchkey Updater.log`).
  Every Latchkey call counts as use, so after a request don't call Latchkey for about 12 minutes
  (the idle wait), then read the status once. A run that finds Latchkey busy for 30 minutes
  tries again 15 minutes later; a failed install, after 6 hours or on the next request.
- Screenshots of the Mac app: `computer_look`, only while the Mac is unlocked, and never acting
  in the user's windows (above).
- No live checks: Claude starts no test sessions against Toni's real data (Toni, 2026-11-23).
  How to test end to end, and how to run evals, is a backlog item (`docs/STATUS.md`).
