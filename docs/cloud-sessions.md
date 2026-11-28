# Cloud sessions (claude.ai/code)

Development happens mostly in cloud sessions. What needs a real Mac happens in a local session
on a Mac (CLAUDE.md, "Two ways to work"); a cloud session builds and tests the Mac app only on
GitHub's Mac runner. Whatever a cloud session's GitHub proxy refuses (tag pushes, releases,
branch deletion, deploys) runs in GitHub Actions, started by a merge to main or by
repository_dispatch.

Everything in CLAUDE.md applies. A cloud session (`CLAUDE_CODE_REMOTE=true`) is a fresh Ubuntu
24.04 VM, run as root, with one clone of this repository: no Swift, Xcode, or macOS, and none of
the gitignored local files (`.env`, `Local.xcconfig`). Started from claude.ai/code or the phone it
has the user's connectors, Latchkey included (used to reach a Mac only for a live check the
person running the session asks for); started with `claude --cloud` it has none. In addition:

- No worktree: the VM's clone is the session's own. Skip `EnterWorktree`, `ExitWorktree` and
  `link-local-files.sh`. Git as in CLAUDE.md, "Git, CI and PRs": one branch and one pull request
  per increment, pushed early (the VM is reclaimed), never replaced; main merged in, never
  rebased onto; squash-merged once `CI gate` is green (`script/stage post-merge <PR>`). Pull requests go through the REST API
  (`gh api repos/tonimelisma/latchkey/pulls -f head=<branch> -f base=main -f title=… -f body=…`)
  or the GitHub MCP tools (`create_pull_request`, `enable_pr_auto_merge` with method squash,
  `update_pull_request_branch` to merge main in on GitHub); GraphQL through the session's proxy
  doesn't work, so `gh pr …` fails. The proxy refuses tag pushes, release writes and branch
  deletions: releases happen in the workflows below, and branches are deleted by GitHub (merged)
  or `branch-cleanup.yml` (closed), never by a session or through Latchkey on the Mac.
- The session-start hook runs `scripts/cloud-setup.sh` (jq, lsof, the pinned ShellCheck, uv; Go
  modules, the pinned Go tools and Semgrep, and test builds warm in the background, logged to
  `~/.cache/latchkey-cloud-setup.log`, done when `…log.done` exists). Never put a secret (a key
  or token) in the environment: everyone using it can read it (its one variable, below, is the
  exception).
- The environment: cloud sessions run in one claude.ai environment shared by several projects.
  Its only variable is `MELISMA_SECRETS_CLIENT_SECRET`, the client secret of an Entra app that
  may read the development vault and the one release secret `latchkey-reports-private-key`
  (the vault and identity details live in the private repository that manages them). Every
  other secret a tool needs it reads from the vault itself when it runs (nothing written to
  disk): `relay/internal/keyvault` signs in as that app when the variable is set, and says in
  its error which secret it couldn't read and why, never a value. No network secrets and no
  `request_credential`. Network: "Limited" plus `login.microsoftonline.com`, the two vaults'
  hosts, the problem-report intake, and `semgrep.dev`, `vuln.go.dev` and `api.osv.dev`
  (`make security`, below).
- Relay and Linux program: `make test`, `make lint` and `make script-tests` in `relay/` and
  `linux/` run here. `make security` also fetches from `semgrep.dev`, `vuln.go.dev` and
  `api.osv.dev`, which the default "Limited" network blocks; they work once those are in the
  environment's allowed domains. Docker is there for `make test-linux` and `make check`. Start a
  full `make test` once the warm-up is done (its `.done` file): the relay's timing tests are
  sensitive to a busy 4-CPU VM. On Linux, `make lint` also checks the Linux-only files the Mac
  never sees (`*_linux.go`).
- Releases run in GitHub Actions (CLAUDE.md, "Git, CI and PRs"; actions pinned by SHA, checked
  by `scripts/tests/ci_tools_test.sh`). Started when CI passes on main for a commit that changed
  their folder since their last release, or from here with repository_dispatch, which the proxy
  allows (`gh api repos/tonimelisma/latchkey/dispatches -f event_type=<type>`):

  | Workflow | After CI on main, when changed | Dispatch type | Environment | What it does |
  |---|---|---|---|---|
  | `ci.yml` | every push, pull request, daily | | | relay, Linux, scripts, process checks, the Mac app (when `macos/` changed); `CI gate` |
  | `relay-image.yml` | `relay/` | `relay-image` | `production` | checks, then the signed image; hosts that verify the signature pull it |
  | `linux-release.yml` | `linux/` | `linux-release` | `release` | tag `linux-<x.y.z>`, signed release; servers update within a day |
  | `mac-tag.yml` | `macos/` | `mac-tag` | `release` | tag `mac-<x.y.z>`, signed release and update feed; installed Macs update themselves |
  | `branch-cleanup.yml` | a pull request closes; daily | `branch-cleanup` | `branches` | deletes branches whose pull request is closed (`scripts/branch-cleanup.sh`) |

  Follow a run with `gh api repos/tonimelisma/latchkey/actions/runs?per_page=5` and its jobs'
  logs; the logs are public, so nothing the scripts print may be private (they hide the
  values they read with `::add-mask::`, and the secrets are hidden by GitHub). No workflow and no
  identity ever reaches an installed Linux server: it only pulls signed Linux releases.
  Secrets are the maintainer's (`docs/development.md`, "Maintainer setup"); a session never
  handles a secret's value. The release jobs read theirs from Azure Key Vault with the job's
  identity token, and mask each value.
- The hosted relay's server (it also runs the feedback intake; run outside this repository):
  anything that happens there is done by that server's own agent, never by a session here or
  through Latchkey's shell (decided 2026-11-23). A session that needs something there writes a self-contained prompt for the maintainer to
  give that agent: the goal, the current state, the rules (no interruption, nothing secret
  written in public), what to check, and what to report back.
- Mac app without the Mac: `ci.yml`'s Mac jobs lint, build and test the app on GitHub's macOS
  runner for every change to `macos/`; they are part of `CI gate` (they pass at once when
  `macos/` didn't change). A run is four jobs side by side, about 4.5
  minutes (decided: "split the slow step into parallel jobs, get it to 5 minutes"; GitHub runs at
  most five macOS jobs at once on this plan). Job 3 also runs the Mac app's end-to-end check
  on its build (below). On main, code its pull request already tested exactly (the same tree)
  is only built, for the cache. Each job builds (about 1.5 minutes: Xcode's compilation cache and the
  Swift packages are kept between runs, saved by job 0) and runs its share. Job 0 lints, runs the update and unit tests, then
  the tests of short time limits alone (`macos/scripts/quiet-suites.txt`). All four run the
  tests with web pages or time limits in two test programs each, each program one test at a
  time, split by measured time (`macos/scripts/shard-suites.py` reads
  `macos/scripts/suite-seconds.txt`; each run prints fresh `SUITE` seconds to copy there when
  the split drifts; a new suite counts 20 s). Pushing
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
  key in `LATCHKEY_REPORTS_KEY` and the intake's token in `LATCHKEY_INTAKE_TOKEN`; when they aren't
  set (the usual case) it reads both from Key Vault itself (`latchkey-reports-private-key`,
  base64 as `latchkey-reports keygen` writes it, and `latchkey-intake-developer-token`; the
  environment, above). Report contents stay
  in the session's output.
- End to end and evals (spec 015): `e2e.yml`'s `e2e-linux` and the Mac build's job 3 run the
  checks the changed files select (`relay/e2e/capabilities.json`) with a real MCP client through
  a private relay; the checks are reported, not required. Tool descriptions aren't compared
  with saved copies (the snapshots were removed, decided 2026-11-26). Docker Hub refuses this VM's pulls (rate limit), so the
  Linux check runs on GitHub, not here. Eval results a local session sent (`make -C macos
  evals ARGS=--send`; there is no weekly run or reminder, decided 2026-11-25) are read with `go run
  ./cmd/latchkey-reports evals`. `--send` signs with the developer's private key, which the
  sender reads exactly as `latchkey-reports` does (`keyvault.ReportsKey`; no key file on disk).
- No Mac (CLAUDE.md, "Two ways to work"): a cloud session never uses
  Latchkey to reach the developer's own Mac while developing: no builds, tests or lint through
  `shell_run`, no requests to the Mac's updater, no `computer_look` screenshots. The Mac app is
  built, linted and tested by `ci.yml` on GitHub's Mac runner; what needs
  a real Mac waits for a local session (spec 016). The one exception is a live check the maintainer asks
  for in this session; it never quits or installs Latchkey (spec 004 FR-309).
- No live checks: Claude starts no test sessions against anyone's real data, except one the
  person running the session asks for. The test strategy, with a sandbox Mac for real-Mac
  checks, is spec 016 (`docs/requirements/test-strategy.md`).
