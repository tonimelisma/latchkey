# Commands

Moved from CLAUDE.md on 2026-11-22 (it keeps the essentials).

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
- `make script-tests`: tests of the repository scripts (no server, no network)

- `make mac-check`: the Mac app's real connection code against a private relay (battery vs
  pmset, tool off, silent network cut, reconnect)

End to end and evals (spec 015; `relay/cmd/e2e`, run in `relay/`):
- `go run ./cmd/e2e pick -base <ref>` (or `-files a,b`): which checks the changed files select,
  from `e2e/capabilities.json`; `e2e.yml` runs it on every pull request
- `go run ./cmd/e2e relay [-update-snapshots]`: the relay's own tools through a private relay and
  a pretend Mac (headless Chrome), compared with `e2e/toolsnaps/relay`
- `go run ./cmd/linuxcheck -toolsnaps e2e/toolsnaps/linux [-update-snapshots]`: the Linux check,
  with the Linux tools' snapshots (Docker must run)
- `go run ./cmd/e2e mac -checks core,files,shell,browser [-update-snapshots]`: the Mac app's real
  tools (the Swift host test `E2EHostTests`) through a private relay; meant for GitHub's
  throwaway Mac runner (it uses that Mac's home folder, shell and Downloads)
- A snapshot that differs fails `e2e.yml`; the job's artifact `toolsnaps-<kind>` holds the new
  files to commit in the same pull request
- Weekly, on an Apple silicon Mac with Tart and Go, from any clone: `macos/scripts/eval-image.sh`
  once (the test Mac image; a person approves its permissions), then
  `macos/scripts/weekly-eval.sh` (results in `e2e-results/`, ignored by git) or `--send` (also
  sealed to the developer's intake). Nothing to approve per run.
- `go run ./cmd/latchkey-reports evals [-this-week [-quiet]]`: the sent weekly results, joined by
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
  Mac's updater (`scripts/auto-update.sh`, a launchd agent set up by `scripts/updater-setup.sh`)
  runs it by itself for every new tag
- Signing: copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set your team ID

Linux server program (run in `linux/`, its own Go module; spec 010):
- `make test` / `make lint`: tests that run anywhere (Linux-only ones skip), golangci-lint
- `make test-linux`: every test on Debian with systemd in Docker (Docker must run)
- `make check`: end to end: private relay, pretend Mac, the program installed by install.sh in a
  Debian container, a real MCP client (`-claude` in `relay/cmd/linuxcheck` adds Claude Code)
- `make release`: build, sign (`SERVER_SIGNING_KEY` in `.env`), tag the commit (must be origin/main)
  `linux-<next number>` and publish it there (every increment ships)

Screen states (`macos/scripts/state-check/`; not run: no test sessions against Toni's real data,
2026-11-23; their cases that need Claude or the apps run as spec 015's eval tasks): `state-check.sh run|wait|report <folder outside the
repo>` tries every use case in `cases.json` through the hosted relay with real Claude Code, in
the screen state the Mac is in (unlocked, locked, lid closed; Toni dropped display asleep but unlocked, 2026-11-04); `report` writes
`docs/use-cases.md`. Each run also logs what took focus, raised a window, moved the pointer, or
used the clipboard (`<state>/focus.log`; `LATCHKEY_CHECK_PARALLEL=1` runs one group at a time so
each line belongs to one group). Needs `LATCHKEY_CHECK_TO` (Toni's own address, from `CLAUDE.local.md`).
Claude Code here runs on Toni's Claude subscription; the dollar cost it prints is only what the
same use would cost paid per use.
