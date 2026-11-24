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
| Relay (Go) | `relay/` | `make test`, `make lint`, `make run`, `make claude-check`, `make mac-check` |
| Linux server program (Go) | `linux/` | `make test`, `make lint`, `make test-linux` (every test on Debian with systemd in Docker), `make check` (end to end: relay, pretend Mac, the program installed in a container, a real MCP client); releases by `.github/workflows/linux-release.yml` |
| Mac app and helper (Swift) | `macos/` | `make test`, `make lint`, `make run`, `make dmg`, `make install` (CI's newest release tag: build, install into Applications, start, and fail if the update lost the pairing; the Mac's updater runs it for each new tag), `scripts/readme-shots.sh` (redraws the app's pictures in docs/images) |
| End-to-end tests and evals (spec 015) | `relay/cmd/e2e`, `relay/e2e/`, `.github/workflows/e2e.yml` | every pull request: the changed capabilities checked with a real MCP client through a private relay on GitHub's Linux and Mac runners, and every tool compared with its snapshot (`relay/e2e/toolsnaps`); weekly, from any clone on an Apple silicon Mac with Tart: `macos/scripts/eval-image.sh` once, then `macos/scripts/weekly-eval.sh`, where real Claude Code does about 20 tasks 3 times each in a throwaway test Mac (results in `e2e-results/`) |
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
gitignored files: `.env`, `macos/Config/Local.xcconfig`, and `CLAUDE.local.md`.
