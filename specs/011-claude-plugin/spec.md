# Spec 011: Latchkey plugin for Claude — WHAT and WHY

Status: Built (2026-11-01). Toni asked on 2026-11-01 for the spec started "as if from a blank
slate", the repository arranged for it, and everything as finished as possible while he was
away, with no questions in between. The choices Claude made for him (plan.md "Choices made for
Toni") were put to him for approval on 2026-11-01; none is his decision until he answers.
Scope: a Claude plugin that teaches Claude how to use Latchkey and how to set it up, published
from this repository so people can add it on claude.ai, in Claude Desktop and Cowork (and then
on their phones), and in Claude Code.
Out of scope for now: a listing in Anthropic's plugin directory and a plugin that fills in a
relay's address (later, with the directory listing; Toni, 2026-10-22: "much later"); anything
that runs code on the person's computer.

## Problem

Claude learns about Latchkey only from the connector's tool descriptions, and only once the
connector is connected. Three things fall through:

1. **Before setup.** Someone who asks Claude "can you check my Mac?" without Latchkey connected
   gets "I can't", with no path forward. Claude knows nothing about Latchkey to help them set it
   up, pair a server, or fix a connector that stopped working.
2. **Across tools.** Each tool description covers its own tool. How to choose between machines,
   what to do when one is offline or a tool refuses, and how to carry a task across tools and
   machines has nowhere to live. The relay's server instructions say some of it, but Claude's
   apps aren't documented to show them to Claude (research.md R4), so the relay repeats every
   rule in the tool descriptions.
3. **Setting up a relay.** The guide Claude Code follows to set up a person's own relay is a
   file in `docs/` that the Mac app's Copy Request points at; nothing else finds it.

## Who

- **The Owner**: as in spec 001: uses Claude on the web, Desktop, a phone, or Claude Code.
- **Claude**: in any of those apps, with or without Latchkey's tools.

## User stories

### US1 (P1): Claude helps me get Latchkey working
1. Given I added the plugin but no connector, when I ask "what's my Mac's battery?", then
   Claude tells me Latchkey isn't connected in this chat and how to connect it.
2. Given I ask "how do I connect my Linux server?", then Claude gives me the steps: the install
   line from my relay's account page, the code on `/link`.
3. Given I have no relay and use Claude Code, when I ask it to set one up, then it follows the
   relay guide in the plugin.

### US2 (P1): Claude uses my machines well
1. Given two machines and a request that fits both, then Claude checks which machines there are
   and asks or picks the one I named, and says which it used.
2. Given my Mac is asleep, then Claude tells me once, plainly, what would bring it back, and
   doesn't keep retrying.
3. Given a tool refuses (a permission, a setting), then Claude tells me what to change on that
   machine, and doesn't get around it with another tool.

### US3 (P1): I add it once and it stays current
1. Given I add the plugin on claude.ai, then it works on the web, in Desktop, and on my phone.
2. Given a new version is published, then my apps get it without my doing anything (claude.ai,
   and Claude Code when the catalog came from claude.ai).

## Requirements

### What the plugin holds

- **FR-1101** The plugin shall consist of instructions for Claude only: no program, no MCP
  server of its own, no hooks, and nothing that runs on the person's computer, so that every
  part of it loads on claude.ai, in Desktop, in Cowork, on phones, and in Claude Code.
- **FR-1102** The plugin shall work with any Latchkey relay, hosted or self-hosted: it shall not
  contain or require a relay's address.
- **FR-1103** When the person asks Claude to do something on, find something on, or check
  their own computer or server, the system shall give Claude how to use Latchkey: choosing a
  machine, reading the state line, a machine that is offline or asleep, a tool that refuses, and
  carrying a task across tools and machines.
- **FR-1104** When the person asks about installing, connecting, pairing, or fixing Latchkey, or
  asks for something on their computer while no Latchkey tools are available, the system shall
  give Claude the steps: what the relay, the machines, and the connector are; connecting Claude
  in each app; pairing a Mac; pairing a Linux server; checking it works; and fixing the common
  failures.
- **FR-1105** When Claude Code has a shell and the person has no relay, the system shall give
  Claude the guide for setting up the person's own relay (spec 009), from the plugin itself.
- **FR-1106** The plugin's text shall not name any capability or tool a machine may offer
  (Constitution III), other than the relay's own `machines` tool: what a machine offers comes
  only from the tools Claude is actually given.
- **FR-1107** The plugin shall never ask Claude to get around a tool's refusal or a setting the
  person chose, and shall never hold secrets or the hosted relay's details.

### Distribution and updates

- **FR-1110** The plugin shall be published from this repository as a plugin catalog that
  people add by the repository's name, on claude.ai (Customize → Plugins → Add marketplace) and
  in Claude Code (`claude plugin marketplace add`), with no submission or review.
- **FR-1111** The plugin shall carry a version, raised with every change, so that apps that
  follow the catalog install each change and don't miss one.
- **FR-1112** The README and the relay's account page shall tell the Owner the plugin exists and
  how to add it, next to connecting Claude.
- **FR-1113** The Mac app's Copy Request shall point at the relay guide in the plugin.
- **FR-1114** (Later, withdrawn from this spec's build: Toni, 2026-10-22, directory "much later")
  A directory listing, and a variant that fills in the hosted relay's address.

### Quality

- **FR-1120** Each change to the plugin shall pass the plugin checker in strict mode and the
  content checks for FR-1101, FR-1102, FR-1106, FR-1107, and FR-1111.
- **FR-1121** Each change to the plugin shall be measured with real Claude, with and without the
  plugin, on pretend Latchkey tools, and shall not make any measured behavior worse; the skills
  shall be shown to help where the plugin claims to (setup, offline machines, choosing a machine).

## Success criteria

- Adding the catalog `tonimelisma/latchkey` on claude.ai and in Claude Code installs the plugin.
- With the plugin, Claude explains how to connect Latchkey when its tools are missing, and tells
  the person about an offline machine without retrying; without it, it does neither as well
  (measured, research.md R8).
- No check or eval needs Toni.
