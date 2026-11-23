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
- `make script-tests`: tests of the deploy and repository scripts (no server, no network)

- `make mac-check`: the Mac app's real connection code against a private relay (battery vs
  pmset, tool off, silent network cut, reconnect)

Hosted relay (docs/cloud-sessions.md, "Releases"): new versions ship by themselves after a merge
(`relay-image.yml` publishes and signs the image; the server's `latchkey-update-apps` checks the
signature, switches, and rolls back an unhealthy one). `deploy/deploy.sh` applies the
configuration (relay.env, compose file, Caddy block, Cloudflare DNS, the Resend domain) and
restarts the running version; `deploy/harden.sh` locks the server and project down. Both run in
the infra workflow (repository_dispatch `infra`, `client_payload[task]` `configure` or `harden`)
as `latchkey-infra` (Workload Identity Federation; set up once with `deploy/gcp-wif-setup.sh`),
with the settings from the environment `infra`'s secrets, or by the owner with a gitignored
`.env` (see the scripts' headers): `CLOUDFLARE_API_TOKEN`, `RESEND_API_KEY` (send-only),
`RESEND_ADMIN_KEY` (full access, only to set up the sending domain), optional `OPERATOR_NAME`,
`OPERATOR_CONTACT`, `OPERATOR_LAW`, `OPERATOR_PROVIDERS`, `BACKUP_DAYS` (they switch on the
relay's terms and privacy pages). A deploy applies only a clean checkout of main and goes back to
the previous settings if the relay doesn't answer. `deploy/backup-schedule.sh` turns on the nightly copy of the server's
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

Screen states (`macos/scripts/state-check/`): `state-check.sh run|wait|report <folder outside the
repo>` tries every use case in `cases.json` through the hosted relay with real Claude Code, in
the screen state the Mac is in (unlocked, locked, lid closed; Toni dropped display asleep but unlocked, 2026-11-04); `report` writes
`docs/use-cases.md`. Each run also logs what took focus, raised a window, moved the pointer, or
used the clipboard (`<state>/focus.log`; `LATCHKEY_CHECK_PARALLEL=1` runs one group at a time so
each line belongs to one group). Needs `LATCHKEY_CHECK_TO` (Toni's own address, from `CLAUDE.local.md`).
Claude Code here runs on Toni's Claude subscription; the dollar cost it prints is only what the
same use would cost paid per use.
