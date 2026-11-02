# Developing Latchkey

Latchkey is in testing (version 0.8): every capability is built and checked live on a real Mac.
There are no releases yet. The app isn't notarized, so a copy built by someone else opens only
after System Settings → Privacy & Security → Open Anyway. The relay's image isn't published yet;
run it from source ([self-hosting.md](self-hosting.md)). Current work: [STATUS.md](STATUS.md).
How the product works: [how-it-works.md](how-it-works.md).


| Part | Where | Commands |
|---|---|---|
| Relay (Go) | `relay/` | `make test`, `make lint`, `make run`, `make claude-check`, `make mac-check` |
| Linux server program (Go) | `linux/` | `make test`, `make lint`, `make test-linux` (every test on Debian with systemd in Docker), `make check` (end to end: relay, pretend Mac, the program installed in a container, a real MCP client), `make release` |
| Mac app and helper (Swift) | `macos/` | `make test`, `make lint`, `make run`, `make dmg`, `make install` (build, install into Applications, start, and fail if the update lost the pairing), `scripts/readme-shots.sh` (redraws the app's pictures in docs/images) |
| Plugin for Claude (skills) | `plugin/` | `make test` (contract checks and Claude Code's validator), `make measure` (eval cases with real Claude, with and without the plugin) |
| Hosted relay deployment | `deploy/` | `deploy/deploy.sh` |
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
plugin/                         The plugin for Claude: two skills, their evals. `make test`, `make measure`.
.claude-plugin/marketplace.json The plugin catalog people add as `tonimelisma/latchkey`.
specs/002-notes-messages/       Notes and Messages (same structure for each capability).
specs/003-files/                Files.
specs/004-shell/                Shell.
specs/005-browser/              Browser control (Safari).
specs/006-computer-control/     Computer control.
specs/007-calendar-reminders-contacts-location/  Calendar, Reminders, Contacts, Location & Maps.
specs/008-mail/                 Mail.
specs/009-easy-relay-setup/     A relay set up by Claude Code.
specs/010-multi-host/           Several machines and Linux servers.
specs/011-claude-plugin/        The plugin for Claude.
docs/best-practices.md          Research on best practices, checked against Latchkey.
docs/threat-model.md            What is protected, attackers, trust boundaries, accepted risks.
docs/self-hosting.md            Run your own relay.
docs/how-it-works.md            The details: what runs where, every tool, privacy, Linux servers, setup.
docs/development.md             This page: commands and repository layout.
docs/images/                    Pictures (the app's views drawn by macos/scripts/readme-shots.sh).
SECURITY.md                     How to report vulnerabilities.
```

Personal deployment details (the hosted relay's address, server, signing team) live only in
gitignored files: `.env`, `macos/Config/Local.xcconfig`, and `CLAUDE.local.md`.
