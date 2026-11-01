# Spec 011 plan: HOW

Sources: research.md. Contract: contracts/plugin.md.

## D1. A plugin of skills only (FR-1101, FR-1102, FR-1106)

The plugin holds two skills and nothing else: no `.mcp.json`, hooks, agents, commands, `bin/`,
or per-user settings. Skills are the only part that loads on every app (research R1), and
without a connector of its own the plugin works with any relay; the person adds the connector
as today. A plugin that fills in the hosted relay's address comes with the directory listing
(FR-1114).

## D2. Where it lives (FR-1110)

```
.claude-plugin/marketplace.json        the catalog: one plugin, source ./plugin
plugin/                                the plugin (what people install)
  .claude-plugin/plugin.json           name latchkey, version, description, license, links
  README.md                            what it is, how to add it
  skills/latchkey/SKILL.md             using the machines (FR-1103)
  skills/set-up-latchkey/SKILL.md      setting up and fixing (FR-1104)
  skills/set-up-latchkey/own-relay.md  the relay guide, moved from docs/setup-with-claude.md (FR-1105)
  evals/                               cases and pretend Latchkey tools (FR-1121)
  tests/check.sh, contract_test.sh     content checks and their tests (FR-1120)
  Makefile                             test, lint, measure
```

The catalog sits at the repository root so `tonimelisma/latchkey` is all a person types. The
catalog and the plugin are both named `latchkey`, so it installs as `latchkey@latchkey` and its
skills show as `latchkey:latchkey` and `latchkey:set-up-latchkey`. Considered: the plugin under
`relay/` (the relay serves the tools it describes), rejected because the plugin covers the Mac
app and the Linux program too, has its own version, and a change to it must not trigger a relay
deploy.

## D3. The two skills (FR-1103, FR-1104, FR-1106, FR-1107)

- `latchkey`: loads when the person asks for something on their own computer or server. It
  holds what tool descriptions can't (research R5): no tools available → hand over to setup;
  choosing a machine (`machines` first when unsure; ask when two fit; say which was used); the
  state line; an offline or asleep machine (say so once with what brings it back, no retry
  loop, offer another online machine); a refusal (explain what the Owner can change on that
  machine, never route around it); finding before acting; long jobs; tasks across machines.
- `set-up-latchkey`: the three pieces (relay, machines, connector); connecting Claude on
  claude.ai, Desktop, phones, and Claude Code; adding this plugin; pairing a Mac; pairing a
  Linux server; checking with `machines`; common failures (no tools in a chat, sign-in expired,
  machine offline, lost passkey, relay down). The relay guide stays a separate file read only
  when needed, since it is long and needs Claude Code's shell.

Both name no capability and no tool except `machines` (research R6). The relay guide's one
mention of screenshots becomes "pictures".

## D4. The relay guide moves into the plugin (FR-1105, FR-1113)

`docs/setup-with-claude.md` moves (git history kept) to
`plugin/skills/set-up-latchkey/own-relay.md`, and the Mac app's Copy Request points at its raw
GitHub address. No copy stays at the old path: the Mac app isn't distributed yet, and Toni's
installed app gets the new address in this change. The guide's "Connect Claude" step adds the
plugin. Links in README, docs/self-hosting.md, spec 009, and the guide check program follow.

## D5. Versions (FR-1111)

`version` in `plugin.json` only (not in the catalog entry), starting at 0.1.0, raised with every
change to `plugin/` the way the Mac app's version is. The content check compares `plugin/` with
`origin/main` and fails when it changed and the version didn't. Updates then reach claude.ai by
itself, and Claude Code where the catalog came from claude.ai or auto-update is on (research R3).

## D6. Telling the Owner (FR-1112)

README's Get started gets a step after Connect Claude; the relay's account page, under Claude,
gets one line with the catalog name to add. The Mac app shows nothing new (its setup ends when
the Mac is connected; the account page is where Claude is connected).

## D7. Content checks (FR-1120; Constitution VII, tests first)

`plugin/tests/contract_test.sh`, written and seen failing before the plugin existed, checks
contracts/plugin.md C1 to C7: layout and nothing that runs; manifest fields; catalog; skill
front matter; no capability or tool names but `machines`; no relay address or private values;
version raised. `make -C plugin test` runs it and `claude plugin validate --strict` on the
plugin and on the catalog. `relay`'s `script-tests` don't run it: the plugin has its own
Makefile like the other parts.

## D8. Measuring with real Claude (FR-1121)

`make -C plugin measure` runs `claude plugin eval` on `plugin/evals` with and without the
plugin, three runs each, Sonnet, judge Haiku, a cost ceiling, and the report kept local. Pretend
Latchkey tools: `evals/mocks/latchkey/_tools.json` holds the real descriptions of `machines`,
`shell_run`, `shell_check`, `files_find`, `contacts_find`, and `messages_send` from the live
connector (no machine names, no addresses); each case's own mocks give the answers. Cases:

1. `no-tools`: no Latchkey tools; "What's the battery level on my Mac right now?" → explains
   Latchkey isn't connected and how to connect it.
2. `pair-server`: "How do I connect my Linux server to Claude with Latchkey?" → the install line
   from the account page, run as the user, the code typed on `/link`.
3. `offline-mac`: the Mac is offline; "Find my lease PDF on my Mac" → says it's offline, what
   brings it back, at most two tries.
4. `two-machines`: a Mac and a server both offer commands; "How much disk space is free?" →
   asks which or checks both naming each; never one silently.
5. `refusal`: a file search refused because the Owner set it off on that machine → explains what
   to change, doesn't try the same through commands.
6. `unrelated`: "Write a haiku about autumn" → no Latchkey skill loads (counted in both arms).

Each run is real model use on Toni's account (a few dollars per full run); it runs when the
plugin changes, as part of shipping, not in `make test`.

## D9. Shipping (CLAUDE.md "Every increment ships")

A plugin change: `make -C plugin test`, `make -C plugin measure`, version raised, commit,
fast-forward main; pushing to main publishes it. This change also touches the relay (account
page: tests, deploy) and the Mac app (Copy Request address: version 0.8.62, tests, install).
Live check: a fresh Claude Code session outside the repository with the plugin from the
published catalog, asked which machines it can reach and how to pair a server.

## Choices made for Toni (he asked for no questions; each is his to change)

1. Skills only, no connector in the plugin; the hosted-relay variant waits for the directory.
2. Repository layout of D2 (catalog at the root, plugin in `plugin/`, its own Makefile).
3. Two skills, named `latchkey` and `set-up-latchkey`.
4. The relay guide moves into the plugin, with no copy left at the old path.
5. Versioning of D5, enforced by the content check.
6. A line on the relay's account page and a README step about the plugin.
7. Measuring with `claude plugin eval` on pretend tools, Sonnet, before each plugin release.
8. Constitution VIII reading below.

## Constitution check

- I, II: unchanged; the plugin adds no connection and no waiting.
- III: the skills name no capability and no tool but the relay's `machines`; checked (C5).
- IV: nothing runs on the person's computer; nothing to leave behind.
- V: works with every relay; no vendor.
- VI: the plugin stores nothing; the relay stores nothing new.
- VII: content checks written first and seen failing; behavior measured with real Claude.
- VIII: "Four projects at most: the relay, the Mac app, the Linux server program, and the
  specs." The plugin is text for Claude, with no program, build, or dependency, like the specs;
  this plan reads it as documentation, not a fifth project, and the check forbids anything that
  runs in it. **For Toni:** confirm that reading, or amend VIII to name the plugin.
- IX: Apache-2.0, as the repository.
