# Latchkey

Use your Mac from Claude on the web, desktop, and phone, even when the Mac is behind a home router.

A native macOS menu bar app keeps an outbound connection to an always-on relay. The relay is the
MCP server Claude talks to: it handles sign-in, remembers the Mac's state, and answers immediately
when the Mac is offline.

## How this repo is organized (spec-driven)

Work starts as a written spec and flows downward. Code is the last step, not the first.

```
memory/constitution.md          Non-negotiable principles. Every plan is checked against them.
specs/001-core/
  spec.md                       WHAT and WHY: user stories, requirements, success criteria. No tech.
  plan.md                       HOW: architecture and technology choices, each traced to a requirement.
  research.md                   Evidence behind the plan, with sources.
  data-model.md                 Entities the relay stores.
  contracts/
    agent-protocol.md           Mac app <-> relay WebSocket protocol.
    mcp-surface.md              What Claude sees: endpoints, OAuth, tools, offline behavior.
  tasks.md                      (next) Ordered, testable tasks generated from plan + contracts.
```

Later capabilities (files, Notes and iMessage, shell, browser and computer control) each get their
own `specs/NNN-name/` folder with the same structure.
