# Cloud sessions (claude.ai/code; 2026-11-21)

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
  `link-local-files.sh`; commit on the session's branch and fast-forward `main` as usual.
  GitHub's proxy refuses branch deletions and tag pushes, so the merged branch stays on GitHub
  until the Mac's `tidy.sh` deletes it, and nothing that tags (`scripts/release-tag.sh`, an
  install, a Linux release) can run here.
- Hooks (`scripts/hooks.sh`): session start runs `scripts/cloud-setup.sh` first (jq, lsof, the
  pinned ShellCheck, uv; Go modules, the pinned Go tools and Semgrep, and test builds warm in the
  background, logged to `~/.cache/latchkey-cloud-setup.log`, done when `…log.done` exists), skips
  `tidy.sh`, and still reports loose ends. The guard is unchanged. No `tidy.sh` after a push. The
  work list for `keep-going.sh` is `~/.claude/worklists/<session id>.md` in the VM.
- Pushes need the private values: the cloud environment's variables `LATCHKEY_PRIVATE_DEPLOY_HOST`,
  `LATCHKEY_PRIVATE_DEPLOY_DNS_ZONE`, `LATCHKEY_PRIVATE_DEPLOY_VM`, `LATCHKEY_PRIVATE_DEPLOY_PROJECT`,
  `LATCHKEY_PRIVATE_DEVELOPMENT_TEAM`, `LATCHKEY_PRIVATE_LATCHKEY_DEFAULT_RELAY_HOST` (Toni sets
  them once; they aren't secrets, only kept out of the repository). Without any of them
  `private-values-check.sh` can't check, and the guard refuses every push. Never put a secret
  (`.env`'s keys and tokens) in the environment: everyone using it can read it.
- Relay and Linux program: `make test`, `make lint` and `make script-tests` in `relay/` and
  `linux/` run here. `make security` also fetches from `semgrep.dev`, `vuln.go.dev` and
  `api.osv.dev`, which the default "Limited" network blocks; they work once those are in the
  environment's allowed domains. Docker is there for `make test-linux` and `make check`. Start a
  full `make test` once the warm-up is done (its `.done` file): the relay's timing tests are
  sensitive to a busy 4-CPU VM. On Linux, `make lint` also checks the Linux-only files the Mac
  never sees (`*_linux.go`).
- Deploys and releases stay on the Mac, in a local session: `deploy/deploy.sh` and
  `make -C linux release` need `.env`'s secrets, the Mac's gcloud and GitHub sign-ins, and a tag
  push. They don't go through Latchkey's `shell_run` either: a production deploy can't be tried
  first, and it writes outside the command's fence (gcloud's settings, Docker, the deploy lock).
  A cloud session merges to `main` and lists "deploy the relay" or "release the Linux program"
  as a step for a local session at the end.
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
  signed ad hoc (no `Local.xcconfig` there); `make -C macos test` in a local session is the
  signed run.
  Never run `make -C macos install` through Latchkey: it quits Latchkey, which stops the command
  mid-install (spec 004 FR-309). The install stays a step for a local session, listed at the end.
- Screenshots of the Mac app: `computer_look`, only while the Mac is unlocked, and never acting
  in the user's windows (above).
- Live checks (`claude -p` and `state-check.sh`) come after the install or deploy, so they run
  in the same local session. A cloud session can try Latchkey's tools through its own connector
  (with the tool list it started with) to look at behavior, but that is not the live check.
