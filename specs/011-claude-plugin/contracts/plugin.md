# Contract: the Latchkey plugin and its catalog

Checked by `plugin/tests/contract_test.sh` (C1 to C7) and `claude plugin validate --strict`.

## C1. Layout: instructions only (FR-1101)

The plugin folder `plugin/` holds only: `.claude-plugin/plugin.json`, `README.md`, `Makefile`,
`skills/<name>/` (Markdown files), `evals/` (cases, graders, mocks; `evals/results/` is never
committed), and `tests/`. It shall not hold `.mcp.json`, `hooks/`, `agents/`, `commands/`,
`bin/`, `.lsp.json`, `output-styles/`, or `settings.json`. Files under `skills/` are Markdown
(`.md`) only.

## C2. Manifest `plugin/.claude-plugin/plugin.json` (FR-1111)

```json
{
  "name": "latchkey",
  "version": "<major.minor.patch>",
  "description": "<one sentence>",
  "author": { "name": "Toni Melisma", "url": "https://github.com/tonimelisma" },
  "homepage": "https://github.com/tonimelisma/latchkey",
  "repository": "https://github.com/tonimelisma/latchkey",
  "license": "Apache-2.0",
  "keywords": ["mac", "linux", "remote", "mcp", "latchkey"]
}
```

`name` never changes. `version` is three numbers. No `mcpServers`, `hooks`, `agents`,
`commands`, `lspServers`, `outputStyles`, `userConfig`, `dependencies`, or `settings` keys.

## C3. Catalog `.claude-plugin/marketplace.json` (FR-1110)

```json
{
  "name": "latchkey",
  "owner": { "name": "Toni Melisma", "url": "https://github.com/tonimelisma" },
  "description": "<one sentence>",
  "plugins": [
    { "name": "latchkey", "source": "./plugin", "description": "<one sentence>" }
  ]
}
```

The entry's `name` equals the manifest's; the entry has no `version` (research R3).

## C4. Skills

| Folder | `name` | Loads when |
|---|---|---|
| `skills/latchkey/` | `latchkey` | the person asks for something on, about, or from their own computer or server |
| `skills/set-up-latchkey/` | `set-up-latchkey` | installing, connecting, pairing, or fixing Latchkey; or no Latchkey tools are available |

Each `SKILL.md` starts with front matter holding `name` (equal to its folder) and
`description` (at most 1024 characters, saying what it does and when to use it). `SKILL.md` is
at most 500 lines; longer material goes in another file of the skill's folder, named from
`SKILL.md` (`own-relay.md`).

## C5. Nothing about capabilities (FR-1106; Constitution III)

No file under `skills/` contains:
- a tool name of the form `<word>_<word>` (such as `shell_run`, `files_find`), or a tool's name
  in backticks other than `machines`;
- a capability's name as Latchkey or macOS calls it: Shell, Files (capitalized), Notes,
  Messages, iMessage, Mail, Safari, Browser, Calendar, Reminders, Contacts, Location, Maps,
  Computer control, Spotlight, Finder, screenshot.

The `latchkey` command's subcommands on a server are named only as `latchkey status` and
`latchkey help`.

## C6. No addresses or secrets (FR-1102, FR-1107)

No file in `plugin/` contains an `https://` address other than github.com,
raw.githubusercontent.com, claude.ai, the documentation examples `relay.example.com` and
`192-0-2-10.sslip.io`, and the cloud provider pages the relay guide uses (google.com,
googleapis.com, dl.google.com). `scripts/private-values-check.sh` covers the deployment's
private values for the whole repository.

## C7. Version raised (FR-1111)

When `plugin/` differs from `origin/main`'s, the manifest's `version` differs from
`origin/main`'s too. (Skipped when `origin/main` has no `plugin/`.)
