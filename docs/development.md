# Developing Latchkey

Latchkey is in testing (version 0.8): every capability is built and checked live on a real Mac.
Every installed version is also the public download (GitHub release `mac-<x.y.z>`, asset
`Latchkey.dmg`; `macos/scripts/publish.sh`, run by CI's Mac release job and by
`make -C macos install`), with Sparkle's update archive and feed (spec 001 FR-072). It is signed for
development, not notarized, so a downloaded copy opens after System Settings → Privacy &
Security → Open Anyway, once per version. The relay's image is published
at `ghcr.io/tonimelisma/latchkey-relay` ([self-hosting.md](self-hosting.md)). Current work: [STATUS.md](STATUS.md).
How the product works: [how-it-works.md](how-it-works.md).


| Part | Where | Commands |
|---|---|---|
| Relay (Go) | `relay/` | `make test`, `make lint`, `make run`, `make security`, `make script-tests` |
| Linux server program (Go) | `linux/` | `make test`, `make lint`, `make test-linux` (every test on Debian with systemd in Docker), `make check` (end to end: relay, pretend Mac, the program installed in a container, a real MCP client); releases by `.github/workflows/linux-release.yml` |
| Mac app and helper (Swift) | `macos/` | `make test`, `make lint`, `make run`, `make dmg`, `make install` (CI's newest release tag: build, install into Applications, start, and fail if the update lost the pairing; the Mac's updater runs it for each new tag), `scripts/readme-shots.sh` (redraws the app's pictures in docs/images) |
| End-to-end tests and evals (spec 015) | `relay/cmd/e2e`, `relay/e2e/`, `.github/workflows/e2e.yml` | every pull request: the changed capabilities checked with a real MCP client through a private relay on GitHub's Linux and Mac runners,; in a local session on an Apple silicon Mac with Tart (spec 016): `macos/scripts/eval-image.sh` once, then `make -C macos sandbox` after every Mac build (the local build in a Tart virtual Mac, every capability with test data) and `make -C macos evals` when tools change (real Claude Code, about 20 tasks 3 times each); results in `e2e-results/` |
| Relay image | `.github/workflows/relay-image.yml` | publishes and signs `ghcr.io/tonimelisma/latchkey-relay` on every relay change on main; hosts that verify the signature pull it (the hosted relay's server is run outside this repository) |
| Cleanup after merging | `scripts/` | `scripts/tidy.sh` (runs automatically after every push and at every session start from Claude Code; removes worktrees as soon as their work is merged); `scripts/loose-ends.sh` lists work not yet on main (checked when a Claude Code session starts and before each turn ends) |

## How this repo is organized (spec-driven)

Work starts as a written spec and flows downward. Code is the last step, not the first.

```
CLAUDE.md                       Instructions for Claude Code sessions (process, rules, commands).
docs/STATUS.md                  Current phase, next steps, risks, open questions.
docs/decisions.md               Index of approved decisions, linking to the specs.
memory/constitution.md          Non-negotiable principles. Every plan is checked against them.
specs/001-core/
  spec.md                       WHAT and WHY: user stories, requirements, success criteria. No tech.
  plan.md                       HOW: architecture and technology choices, each traced to a requirement.
  research.md                   Evidence behind the plan, with sources.
  data-model.md                 Entities the relay stores.
  contracts/
    agent-protocol.md           Mac app <-> relay WebSocket protocol.
    mcp-surface.md              What Claude sees: endpoints, OAuth, tools, offline behavior.
  tasks.md                      Ordered, testable tasks generated from plan + contracts.
relay/                          The relay (Go). `make test`, `make run`; see CLAUDE.md for commands.
macos/                          The Mac app and its helper (Swift, XcodeGen). `make test`, `make run`.
linux/                          The Linux server program (Go). `make test`, `make test-linux`.
specs/002-notes-messages/       Notes and Messages (same structure for each capability).
specs/003-files/                Files.
specs/004-shell/                Shell.
specs/005-browser/              Browser control (Safari).
specs/006-computer-control/     Computer control.
specs/007-calendar-reminders-contacts-location/  Calendar, Reminders, Contacts, Location & Maps.
specs/008-mail/                 Mail.
specs/009-easy-relay-setup/     A relay set up by Claude Code.
specs/010-multi-host/           Several machines and Linux servers.
specs/011-claude-plugin/        The plugin for Claude (withdrawn 2026-11-01).
docs/best-practices.md          Research on best practices, checked against Latchkey.
docs/threat-model.md            What is protected, attackers, trust boundaries, accepted risks.
docs/self-hosting.md            Run your own relay.
docs/setup-with-claude.md       The guide Claude Code follows to set up a relay.
docs/how-it-works.md            The details: what runs where, every tool, privacy, Linux servers, setup.
docs/development.md             This page: commands and repository layout.
docs/images/                    Pictures (the app's views drawn by macos/scripts/readme-shots.sh).
SECURITY.md                     How to report vulnerabilities.
```

Personal deployment details (the hosted relay's address, server, signing team) live only in
gitignored files: `.env`, `macos/Config/Local.xcconfig`, and `CLAUDE.local.md`. Latchkey's tools and
relay read no secret from `.env`: keys and tokens are in Azure Key Vault (below).

## Owner setup (only Toni does these; once; done 2026-11-23)

Moved from CLAUDE.md on 2026-11-26.

- Release secrets (since 2026-11-26): in Azure Key Vault `kv-melisma-release`, managed from the
  private repository `tonimelisma/secrets`, not in GitHub. The release jobs of
  `linux-release.yml` and `mac-tag.yml` fetch them in their first step with the job's GitHub
  identity token (OIDC; no stored credential). The environment `release` holds only the
  variables `AZURE_CLIENT_ID` (Entra app `gh-latchkey-release`, trusted only for
  `repo:tonimelisma/latchkey:environment:release`), `AZURE_TENANT_ID` and `AZURE_KEY_VAULT`.
  Environment name = vault secret: `SERVER_SIGNING_KEY` = `latchkey-server-signing-key`;
  `MAC_CERTIFICATE_P12` = `apple-development-p12-base64` (the "Apple Development" certificate
  with its key, exported from Keychain Access, base64), `MAC_CERTIFICATE_PASSWORD` =
  `apple-development-p12-password`, `MAC_DEVELOPMENT_TEAM` = `apple-development-team`,
  `SPARKLE_PRIVATE_KEY` = `latchkey-sparkle-private-key` (Sparkle's `generate_keys -x`), whose
  public key goes into `SPARKLE_PUBLIC_ED_KEY` in `macos/Config/Base.xcconfig` (public;
  committed).
- Every other consumer reads its secrets from Key Vault itself when it runs (since 2026-11-27;
  no `.env`, no rendered files): an environment variable of the same name wins when set.
  - The Mac: `az login` once (tenant `bd0d0de6-1ba6-42c2-84c6-8e447f1ef6ea`). A local `make
    release` in `linux/` reads `SERVER_SIGNING_KEY` with `az keyvault secret show` from
    `kv-melisma-release/latchkey-server-signing-key`; `latchkey-reports` reads
    `LATCHKEY_REPORTS_KEY` (`kv-melisma-release/latchkey-reports-private-key`) and
    `LATCHKEY_INTAKE_TOKEN` (`kv-melisma-dev/latchkey-intake-developer-token`) through the Azure
    CLI's sign-in (`relay/internal/keyvault`).
  - Cloud sessions: the shared claude.ai environment holds only `MELISMA_SECRETS_CLIENT_SECRET`
    (Entra app `cloud-sessions-reader`), with which `latchkey-reports` signs in
    (`docs/cloud-sessions.md`, "The environment").
  - The hosted relay: with `SMTP_USER` set and no `SMTP_PASSWORD`, it reads the email key
    (`kv-melisma-hosts/resend-api-key`) at startup; on its Google VM `LATCHKEY_KEYVAULT_AUTH=gce`
    makes it sign in as the Entra app `host-pilvi` with the VM's Google identity token (no
    stored credential). The server's setup (its `relay.env`, and `configure`, which reads
    `CLOUDFLARE_API_TOKEN` from `kv-melisma-hosts/cloudflare-api-token` with `az` on the Mac)
    lives in the private repository that runs that server.
- ghcr.io package `latchkey-relay`: Package settings → Manage Actions access → this repository
  with Write (so the image workflow can publish it).
- Optional: required reviewers on the environments `release`, `production`; a tag
  ruleset so only GitHub Actions creates `mac-*` and `linux-*` tags.
