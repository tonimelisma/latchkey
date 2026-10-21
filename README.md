# Latchkey

**Your Mac, at Claude's fingertips from anywhere.**

Latchkey lets Claude on the web, Claude Desktop, and the Claude phone apps use your Mac, even
when it sits at home behind a router with the lid closed. Ask Claude on your phone "what's my
laptop's battery?" and it asks your Mac. When the Mac is asleep or offline, Claude says so right
away, and why, instead of hanging.

Free and open source (Apache-2.0). Apple silicon Macs, macOS 26 or later.

## How it works

```
Claude (web, Desktop, phone)  ──HTTPS──▶  Latchkey relay  ◀──outbound WebSocket──  Mac app
                                          (always on)                               (menu bar)
```

- The **Mac app** lives in the menu bar and keeps one outbound connection to the relay. Nothing
  connects in to your Mac: no open ports, no router settings, no tunnels.
- The **relay** is the MCP server Claude connects to as a custom connector. It handles sign-in
  (passkeys, no passwords), remembers your Mac's last state, and answers instantly when the Mac
  is away.
- **You choose what Claude can do.** Each capability is a switch in the app; a capability that's
  off doesn't exist as far as Claude knows. This first version has one: System info (battery and
  power state). Files, Notes and Messages, shell, and browser control come next.
- **Keep-awake:** while connected, the app keeps the Mac awake, lid closed included, and lets it
  sleep when the battery reaches 15% or it gets too hot.
- **Privacy:** the relay never stores what tools return. It keeps a 30-day list of which tools ran
  and when; the full log, with arguments and results, stays on your Mac for 90 days.

## Get started

1. **Install the Mac app.** Open `Latchkey.dmg`, drag Latchkey to Applications, and open it. The
   setup window walks you through two steps: allow keep-awake in System Settings, and connect to
   a relay (you create your account there with a passkey).
2. **Connect Claude.** On claude.ai, open Settings → Connectors → Add custom connector, and enter
   your relay's address followed by `/mcp`, for example `https://relay.example.com/mcp`. Sign
   in with your passkey and click Allow. The connector then appears in Claude Desktop and the
   phone apps too.
3. **Ask Claude** about your Mac: "Is my laptop online?", "What's my battery?".

The full checklist is in [specs/001-core/quickstart.md](specs/001-core/quickstart.md).

**Uninstall:** move Latchkey to the Trash. It disconnects from your account, restores normal
sleep, removes its background items and local data, and quits.

## Run your own relay

One container with one data volume, behind HTTPS. See
[docs/self-hosting.md](docs/self-hosting.md).

## Status

Version 0.1 is in private testing. Releases are not notarized yet, so the app installs on the
developer's own Macs only. See [docs/STATUS.md](docs/STATUS.md).

## Development

| Part | Where | Commands |
|---|---|---|
| Relay (Go) | `relay/` | `make test`, `make lint`, `make run`, `make claude-check`, `make mac-check` |
| Mac app and helper (Swift) | `macos/` | `make test`, `make lint`, `make run`, `make dmg` |
| Hosted relay deployment | `deploy/` | `deploy/deploy-vps.sh` |

### How this repo is organized (spec-driven)

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
docs/self-hosting.md            Run your own relay.
```

Later capabilities (files, Notes and iMessage, shell, browser and computer control) each get their
own `specs/NNN-name/` folder with the same structure.
