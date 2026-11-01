# Latchkey plugin for Claude

[Latchkey](https://github.com/tonimelisma/latchkey) lets Claude reach your own Macs and Linux
servers from anywhere, through a small relay and a custom connector. This plugin teaches Claude
how to use it well and how to help you set it up. It holds instructions only (two skills): no
program, no connector of its own, nothing that runs on your computer. It works with any Latchkey
relay, hosted or your own.

- **latchkey**: how Claude works on your machines: choosing a machine, a machine that's offline
  or asleep, a tool that refuses, tasks across machines.
- **set-up-latchkey**: connecting Claude, pairing a Mac or a Linux server, setting up your own
  relay (with Claude Code), and fixing a connection that stopped working.

## Add it

On claude.ai or in Claude Desktop: Customize → Plugins → Add marketplace, enter
`tonimelisma/latchkey`, then add the Latchkey plugin. It then works on the web, in Desktop, in
Cowork, on your phone, and in Claude Code when you sign in with the same account. Skills need
code execution turned on (Settings → Capabilities).

In Claude Code:

```
/plugin install latchkey --marketplace tonimelisma/latchkey
```

or, from a shell, `claude plugin marketplace add tonimelisma/latchkey` and then
`claude plugin install latchkey@latchkey`.

The plugin doesn't connect Claude to your relay; add the connector as Latchkey's README says
(Settings → Connectors → Add custom connector, your relay's address followed by `/mcp`).

## Updates

On claude.ai a new version arrives by itself. In Claude Code it does too when the catalog came
from claude.ai; otherwise turn on auto-update for the `latchkey` marketplace in `/plugin`, or
run `claude plugin update latchkey@latchkey`.

## For contributors

The spec is `specs/011-claude-plugin/`. `make test` checks the contract and runs Claude Code's
validator; `make measure` runs the eval cases in `evals/` with real Claude, with and without the
plugin, on pretend Latchkey tools (it uses your Claude account). Raise `version` in
`.claude-plugin/plugin.json` with every change.

Apache-2.0, like the rest of Latchkey.
