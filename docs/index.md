# Docs

What each doc answers. Process and rules: [CLAUDE.md](../CLAUDE.md); what the product is for
users: [README](../README.md).

## Requirements, design and decisions

- Requirements: what each capability does today, each line `[verified]` by tagged tests or
  `unverified:` with why (one file per former spec; `script/process-check` checks them).
  - [Core: connect Claude to the Mac](requirements/core.md) (spec 001)
  - [Notes and Messages](requirements/notes-messages.md) (spec 002)
  - [Files](requirements/files.md) (spec 003)
  - [Shell](requirements/shell.md) (spec 004)
  - [Browser control](requirements/browser.md) (spec 005)
  - [Computer control](requirements/computer-control.md) (spec 006)
  - [Calendar, Reminders, Contacts, Location and Maps](requirements/calendar-reminders-contacts-location.md) (spec 007)
  - [Mail](requirements/mail.md) (spec 008)
  - [Easy relay setup](requirements/easy-relay-setup.md) (spec 009)
  - [Several machines and Linux servers](requirements/multi-host.md) (spec 010)
  - [The Claude plugin (withdrawn)](requirements/claude-plugin.md) (spec 011)
  - [WhatsApp](requirements/whatsapp.md) (spec 012)
  - [Signing in](requirements/sign-in.md) (spec 013)
  - [Problem reports to the developer](requirements/feedback-intake.md) (spec 014)
  - [End-to-end tests and evals](requirements/e2e-evals.md) (spec 015)
  - [Test strategy and two ways to work](requirements/test-strategy.md) (spec 016)
- Design: how each part is built and why; each file names the code it governs.
  - [Core: connect Claude to the Mac](design/core.md)
  - [Notes and Messages](design/notes-messages.md)
  - [Files](design/files.md)
  - [Shell](design/shell.md)
  - [Browser control](design/browser.md)
  - [Computer control](design/computer-control.md)
  - [Calendar, Reminders, Contacts, Location and Maps](design/calendar-reminders-contacts-location.md)
  - [Mail](design/mail.md)
  - [Easy relay setup](design/easy-relay-setup.md)
  - [Several machines and Linux servers](design/multi-host.md)
  - [The Claude plugin (withdrawn)](design/claude-plugin.md)
  - [WhatsApp](design/whatsapp.md)
  - [Signing in](design/sign-in.md)
  - [Problem reports to the developer](design/feedback-intake.md)
  - [End-to-end tests and evals](design/e2e-evals.md)
  - [Test strategy and two ways to work](design/test-strategy.md)
  - [The relay's data model](design/data-model.md) and the [core quickstart](design/core-quickstart.md)
- Contracts: the relay–machine protocol, what Claude sees, and each tool family's contract.
  - [agent-protocol](design/contracts/agent-protocol.md)
  - [eval-result](design/contracts/eval-result.md)
  - [feedback-intake](design/contracts/feedback-intake.md)
  - [login-tools](design/contracts/login-tools.md)
  - [mail-tools](design/contracts/mail-tools.md)
  - [mcp-surface](design/contracts/mcp-surface.md)
  - [plugin](design/contracts/plugin.md)
  - [server-program](design/contracts/server-program.md)
  - [task-format](design/contracts/task-format.md)
  - [trace-files](design/contracts/trace-files.md)
  - [Agent protocol fixtures](design/contracts/fixtures/README.md), read by the Go and Swift tests
- [Decisions](adr/README.md): one ADR per decision; ADR 0001 is the constitution. The dated
  [decision log](decisions.md) keeps every decision row, each pointing at its requirement or ADR.
- [Lessons](lessons.md): rules learned the hard way, and problems still open.

## Research

Dated research behind the designs, findings as of their dates:
  - [2026-10-19-core](research/2026-10-19-core.md)
  - [2026-10-21-notes-messages](research/2026-10-21-notes-messages.md)
  - [2026-10-22-browser](research/2026-10-22-browser.md)
  - [2026-10-22-computer-control](research/2026-10-22-computer-control.md)
  - [2026-10-22-files](research/2026-10-22-files.md)
  - [2026-10-22-shell](research/2026-10-22-shell.md)
  - [2026-10-26-calendar-reminders-contacts-location](research/2026-10-26-calendar-reminders-contacts-location.md)
  - [2026-10-29-mail](research/2026-10-29-mail.md)
  - [2026-10-31-easy-relay-setup](research/2026-10-31-easy-relay-setup.md)
  - [2026-10-31-multi-host](research/2026-10-31-multi-host.md)
  - [2026-11-01-claude-plugin](research/2026-11-01-claude-plugin.md)
  - [2026-11-02-whatsapp](research/2026-11-02-whatsapp.md)
  - [2026-11-20-sign-in](research/2026-11-20-sign-in.md)
  - [2026-11-23-feedback-intake](research/2026-11-23-feedback-intake.md)
  - [2026-11-24-e2e-evals](research/2026-11-24-e2e-evals.md)
  - [2026-11-25-test-strategy](research/2026-11-25-test-strategy.md)
- [Best practices](best-practices.md) for an app like Latchkey, checked against it.
- [Screen states](screen-states.md): what works locked, unlocked and with the lid closed.

## Using and running Latchkey

- [How it works](how-it-works.md): what runs where, every tool, privacy, Linux servers, setup.
- [Use cases](use-cases.md): what Claude can do on a Mac, and in which screen state.
- [Self-hosting](self-hosting.md): run your own relay. [Set one up with Claude](setup-with-claude.md):
  the guide Claude Code follows.
- [Threat model](threat-model.md): what is protected, attackers, trust boundaries, accepted risks.

## Developing

- [Development](development.md): the parts, the repository layout, maintainer setup.
- [Commands](commands.md): every command beyond CLAUDE.md's.
- [Cloud sessions](cloud-sessions.md) and [worktrees in a local session](git-worktrees.md).
- [Regression coverage](regression-coverage.md): what covers each case of the retired hand-run kit.
- [Status record](STATUS.md): the history of what was built, found and checked, by date. Open
  work lives in GitHub issues.
- [Leftovers](ideas/leftovers.md): ideas once collected, and what became of them.
