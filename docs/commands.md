# Commands

The commands beyond CLAUDE.md's "Commands".

Relay (run in `relay/`):
- `make test`: all tests, with the race detector (includes a headless-Chrome test; skipped if
  Chrome is missing)
- `make test-short`: the same without the browser test
- `make lint`: golangci-lint (pinned in the Makefile) with gofumpt; must report 0 issues
- `make fmt`: format
- `make run`: run locally with development defaults (data in relay/.data/, ignored by git)
- `make security`: every security check (known vulnerabilities, committed secrets, Semgrep,
  ShellCheck, tidy modules)
- `make script-tests`: tests of the repository scripts (no server, no network)

- The Mac app's connection checks (battery vs pmset, tool off, silent network cut, reconnect)
  are sandbox Mac checks (spec 016): `relay/e2e/sandbox-checks.md`

End to end and evals (spec 015; `relay/cmd/e2e`, run in `relay/`):
- `go run ./cmd/e2e pick -base <ref>` (or `-files a,b`): which checks the changed files select,
  from `e2e/capabilities.json`; `e2e.yml` runs it on every pull request
- `go run ./cmd/e2e relay`: the relay's own tools through a private relay and a pretend Mac
  (headless Chrome)
- `go run ./cmd/linuxcheck`: the Linux check (Docker must run)
- `go run ./cmd/e2e mac -checks core,files,shell,browser`: the Mac app's real
  tools (the Swift host test `E2EHostTests`) through a private relay; meant for GitHub's
  throwaway Mac runner (it uses that Mac's home folder, shell and Downloads)
- Sandbox Mac (spec 016; a local session on an Apple silicon Mac with Tart, Xcode and Go, from
  any clone; Tart: `brew install openai/tools/tart`, after `brew trust --formula
  openai/tools/tart openai/tools/softnet`): `make -C macos sandbox` builds the working tree,
  signs it with the sandbox's own identity "Latchkey Sandbox" (a self-signed certificate in a
  keychain of its own, `~/Library/Keychains/latchkey-sandbox.keychain-db`; never the login
  keychain, `Local.xcconfig` or a developer certificate, and nothing is trusted, so no dialog),
  installs it in a Tart copy of the image `latchkey-eval` and checks every capability with test
  data (`ARGS="--checks files,notes"` for some); the copy is kept for the next run until
  `make -C macos sandbox-stop`. Results in `e2e-results/` (ignored by git). Evidence only for an
  unlocked virtual Mac with test data. About 40 GB of free disk for the image. To look into a
  check by hand, inside the copy (`tart exec <copy> /bin/zsh -lc '…'`):
  `cd ~/latchkey-eval-run && ./e2e-bin sandbox -call 'tool {"arg": 1} ;; !sleep {"s": 2} ;; !osa {"script": "…"}'`
  calls tools through the copy's relay and prints the answers.
- Evals (spec 015/016): `make -C macos evals` (the local build in the sandbox), `ARGS=--release`
  (the newest release; its signature needs its own permission grants in the image), `ARGS=--send`
  (also sealed to the developer's intake). Real Claude Code does about 20 tasks 3 times each. It reads
  the Claude token from the login keychain item `latchkey-eval-claude-token` and refuses one
  that isn't whole. To make it, run `claude setup-token` in a wide pseudo-terminal (`script -q -t
  0 FILE zsh -c 'stty cols 2000; claude setup-token'`; a narrow one wraps the token), have the
  owner click Authorize, and pipe the token from FILE into `security -i` (never printed).
- Once per Mac: `macos/scripts/eval-image.sh` (the test Mac image, about 1 hour the first time:
  a 27 GB download). It runs to the end by itself with no window: it writes Latchkey's
  permissions into the test Mac's privacy databases and answers Connect inside it.
- `go run ./cmd/latchkey-reports evals [-this-week [-quiet]]`: the sent eval results, joined by
  run and compared with the one before (new failures, fixed, flaky)

Hosted relay: new versions ship by themselves after a merge (`relay-image.yml` publishes the
image and signs it with cosign, keyless; hosts that verify the signature pull it). The hosted
relay's server and its deployment live outside this repository.
Operator commands run inside the relay's container: `docker exec latchkey-relay /relay account
list | account suspend <email> [reason] | account unsuspend <email> | account delete <email> |
block <email> [reason] | unblock <email> | block list`; `relay reset-keys --confirm` (relay
stopped) deletes the stored keys when the key file is lost. Any other argument prints the list
and exits 2; no arguments starts the server.

Mac app (run in `macos/`; `project.yml` is the source, the `.xcodeproj` is generated):
- `make test`: unit and contract tests (Swift Testing); exit code is the result
- `make lint` / `make fmt`: swift-format
- `make build` / `make run`: build, or build and open the app
- `make dmg`: the installable disk image, `build/Latchkey-<version>.dmg`, for a commit that
  already has its release tag (CI's `mac-tag.yml` gives one)
- `make install`: CI's newest release tag, built, installed into /Applications and started; the
  Mac's updater (`macos/scripts/auto-update.sh`, a launchd agent set up by
  `macos/scripts/updater-setup.sh`)
  runs it by itself for every new tag
- Signing: copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set your team ID

Linux server program (run in `linux/`, its own Go module; spec 010):
- `make test` / `make lint`: tests that run anywhere (Linux-only ones skip), golangci-lint
- `make test-linux`: every test on Debian with systemd in Docker (Docker must run)
- `make check`: end to end: private relay, pretend Mac, the program installed by install.sh in a
  Debian container, a real MCP client (`-claude` in `relay/cmd/linuxcheck` adds Claude Code)
- `make release`: build, sign (`SERVER_SIGNING_KEY`, or read from Key Vault with `az login`), tag the commit (must be origin/main)
  `linux-<next number>` and publish it there (every increment ships)

Screen states: the hand-run kit (`state-check`) was retired 2026-11-26 (spec 016). What covers
each case: `docs/regression-coverage.md`; what only a person at a real Mac can run (locked, lid
closed, real accounts): `docs/screen-states.md`, "the requester's conditions".
