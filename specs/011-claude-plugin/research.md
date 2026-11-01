# Spec 011 research

Read 2026-11-01 from Anthropic's documentation, and checked by experiment where noted. Claude
Code 2.1.303 on this Mac.

## R1. What a plugin is, and what loads where

A plugin is a folder with `.claude-plugin/plugin.json` and any of: skills
(`skills/<name>/SKILL.md`), commands, agents, hooks, an MCP configuration (`.mcp.json`), LSP
servers, output styles, programs in `bin/`. Per Anthropic's support table
(claude.com/docs/plugins/platform-support), where "Chat" is claude.ai on the web, in Desktop,
and in the phone apps:

| Part | Chat | Cowork | Claude Code |
|---|---|---|---|
| Skills | loads | loads | loads |
| Commands | loaded as a skill | `/plugin:command` | `/plugin:command` |
| Agents, hooks | ignored | loads | loads |
| Remote MCP server, fixed address | on the plugin's Connectors tab; the person connects and signs in | same | loads |
| Remote MCP server whose address uses `${user_config.*}` | ignored | ignored without a default | prompts for the value |
| Local MCP server | ignored | only on the person's computer | loads |
| `bin/` at the top level | the whole plugin is refused | refused | loads |

Plugins are added on claude.ai or in Desktop (Customize → Plugins) and then follow the account
to the phone, Cowork, and Claude Code (as `<name>@synced`). Phones can't add one.

"Adding a plugin doesn't add a connector to your account or sign you in to anything", and "the
plugin's skills load whether or not you connect anything" (claude.com/docs/plugins/overview).

**Consequence for Latchkey:** a plugin can't carry a per-person relay address anywhere but
Claude Code. A plugin with a connector must name one fixed relay, which is wrong for everyone who
runs their own. A plugin of skills only works with every relay.

## R2. Distribution

- **Own catalog in a Git repository**: `.claude-plugin/marketplace.json` at the repository root
  lists plugins and where each lives (a relative path such as `./plugin` works). "Once the file is
  in the repository, the plugin is published, with no submission form"
  (code.claude.com/docs/en/plugins/publish). claude.ai: Customize → Plugins → Add → Add
  marketplace, with `owner/repo` (up to 25 catalogs per person). Claude Code:
  `claude plugin marketplace add owner/repo`, then `claude plugin install latchkey@latchkey`.
  A person can't have two catalogs with the same name.
- **Anthropic's directory** (claude.ai/directory/manage): any paid plan can submit a GitHub
  repository; every version is validated and security-scanned, a person reviews the first
  listing; later versions can go live by themselves. Needs a README (40 words or more) and a
  license. Anthropic asks that a remote MCP server the plugin uses also be submitted as a
  connector. Deferred (Toni, 2026-10-22).
- **Upload** a zip at Customize → Plugins (one person). **Organization** settings for Team and
  Enterprise. Neither fits an open-source project.

## R3. Versions and updates

- `version` in `plugin.json` "pins the plugin to that version until you change it": commits
  without a new version reach nobody (code.claude.com/docs/en/plugins-reference). Without
  `version`, the version is the commit (12 characters). Don't set it in both the manifest and the
  catalog entry.
- claude.ai: plugins from a catalog update from their source by themselves ("you get it on your
  account automatically, with nothing to accept"); GitHub catalogs can "Sync automatically".
- Claude Code: background auto-update is on for catalogs added on claude.ai and off for other
  third-party catalogs; the person turns it on in `/plugin` → Marketplaces, or runs
  `claude plugin update latchkey@latchkey`. No release channels; a branch or tag can be pinned
  with `owner/repo#ref`.

## R4. Skills next to a connector

- Anthropic: "MCP connections give Claude access to tools, while skills teach Claude how to use
  those tools effectively" (support.claude.com, What are skills). A skill "can tell Claude how to
  use a connector, but it can't reach the service itself" (claude.com/docs/skills/how-to).
- Loading: Claude always sees each skill's name and description; it reads `SKILL.md` when the
  task fits and other files in the skill's folder only when needed. "The description is the only
  part Claude sees before deciding to use the skill."
- On claude.ai skills run in the code sandbox, so they need code execution turned on (Settings →
  Capabilities). Without it the person simply doesn't get them.
- The MCP `instructions` field: Claude Code shows it to Claude (seen in this session's own
  prompt, which quotes the relay's instructions). No Anthropic page says claude.ai does. The relay
  already repeats every rule in the tool descriptions (spec 010 plan), and the skill is the one
  place Anthropic documents for guidance across tools on every app.

## R5. What the tool descriptions already cover

Read from the live connector (2026-11-01): `machines`, `shell_run`, `shell_check`,
`files_find`, `contacts_find`, `messages_send` describe their own arguments, limits, the
`machine` argument ("Leave it out when only one machine offers this tool"), and refusals. Not
covered anywhere Claude sees on every app: what to do with no tools at all, an offline machine
beyond the one answer, not routing around a refusal, and carrying a task across machines. That's
what the skill holds; it repeats no per-tool rule.

## R6. Constitution III and a skill that is the same for everyone

A skill's text is the same for every person; the tools differ per person and per machine. If the
skill named a capability ("send a text with messages_send"), Claude would read about it even
where the Owner turned it off, which Constitution III forbids. So the skill names no capability
and no tool except the relay's `machines`, and a check enforces it (contracts/plugin.md C5).

## R7. Checking a plugin

- `claude plugin validate --strict <dir>` checks the manifest, skills, and catalog; warnings fail.
- `claude plugin eval <dir>` runs each case's prompt in a sandboxed `claude -p` with the plugin
  and again without it, and scores both (graders: regex, tool_used, tool_order, file_exists,
  llm judge, baseline). Each run is a real model call on the account.
- Experiment (2026-11-01): a mock under `evals/mocks/latchkey/` stands in for a server the
  plugin does **not** declare: the run reported `latchkey[standalone](machines=fixed)` and Claude
  called it. So the evals can give Claude pretend Latchkey tools with their real descriptions
  (`_tools.json`, copied from the live connector) and canned answers, without touching a real
  machine. Personal MCP servers and claude.ai connectors never load in an eval run.
- The worktree guard in this repository refuses any command line containing the word `eval`;
  `plugin/Makefile` runs the command through make, which the guard doesn't see.

## R8. Measured effect

See plan.md D8 for the cases. Results are recorded in tasks.md T1108 after each run.

## Options considered

| Option | For | Against | Chosen |
|---|---|---|---|
| No plugin; better tool descriptions | Nothing new to keep | Can't help before setup; no place for guidance across tools on claude.ai | No |
| **Skills-only plugin from this repository** | Works with every relay; no review; updates by itself on claude.ai | One more thing to version and test; needs code execution on claude.ai | **Yes** |
| Plugin that also names the hosted relay | Fills the address in | Wrong for self-hosters; the person still signs in; commits to a public relay | Later, with the directory |
| Directory listing now | Found by browsing | Review, public service, terms; deferred by Toni | Later |

Sources: claude.com/docs/plugins/overview, /platform-support, /build, /submit, /admin;
claude.com/docs/directory/publish; code.claude.com/docs/en/plugins/publish, /plugins-reference,
/plugin-marketplaces, /plugins/loading, /plugin-evals; claude.com/docs/skills/overview, /how-to;
support.claude.com/en/articles/12512176-what-are-skills; claude.com/blog/skills-explained;
anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills.
