# Spec 010 research: several machines and Linux servers

Checked 2026-10-31. "Unverified" means no primary source was found.

## One connector or one per machine

Chosen: one connector for every machine (Toni, 2026-10-31).

- Free Claude accounts can add one custom connector; Pro and up have no stated limit
  (https://support.claude.com/articles/11176164-use-connectors-to-extend-claude-s-capabilities).
  A connector per machine, or a Mac connector and a Linux connector, would leave free users with
  one machine.
- Anthropic's tool-design guidance: too many or overlapping tools distract the model; merge tools
  and group them with name prefixes
  (https://www.anthropic.com/engineering/writing-tools-for-agents). Two connectors would each
  carry `shell_run` and the file tools.
- The common pattern for many targets behind one server is an argument on every tool plus a tool
  that lists the targets: Kubernetes MCP servers add a `context` argument to every tool when
  several clusters exist (https://socket.dev/npm/package/kubernetes-mcp-server/overview/0.0.53,
  https://raw.githubusercontent.com/dockndevai/mcp-kubernetes/HEAD/README.md).
- Separate servers are recommended when sensitivity or the tool count differs a lot
  (https://docs.glean.com/administration/platform/mcp/best-practices,
  https://aischool.lillytechsystems.com/mcp-server/best-practices.html); Teleport shows each
  protected server as its own entry in Claude
  (https://goteleport.com/docs/ver/19.x/connect-your-client/model-context-protocol/mcp-access.md).
  The gain is a per-machine switch in Claude's settings. Left for later if wanted (an extra
  address per machine on the same relay).

## Machine names never go into tool names or schemas

claude.ai keeps its own copy of a connector's tool list and doesn't reliably refresh it; a
reported custom server's new tool never appeared until reconnecting
(https://github.com/anthropics/claude-ai-mcp/issues/137), and connectors have a manual "Refresh
tools list" (https://help.usewheelhouse.com/en/articles/15908885-refreshing-your-claude-connector-to-get-new-tools).
Options weighed:

| Option | For | Against |
|---|---|---|
| Tool per machine (`homeserver_shell_run`) | Clear | A new machine is invisible until a manual refresh; tool count grows per machine |
| `host` as a fixed list (enum) in the schema | Claude sees choices | Same staleness when a machine is added or renamed |
| `host` as plain text, plus a machines tool and the state line | Never stale; one copy per tool | Claude must ask or list first when several machines fit |

Chosen: plain text, with FR-1005's rule when it is left out.

## Headless pairing

The OAuth device authorization grant (RFC 8628, https://www.rfc-editor.org/rfc/rfc8628) is the
standard for devices without a usable browser: the device shows a code, the user approves on
another device, the device polls the server. Latchkey's pairing isn't OAuth to Claude but the
same shape fits: setup asks the relay for a code, shows link and code, and polls until the Owner
approves on the relay's page. Chosen over a code made on the web page and pasted into the server
(Toni, 2026-10-31).

## Sudo and the write fence

On the Mac, commands run inside macOS's sandbox with a write allowlist (spec 004 FR-317). The
Linux equivalents (Landlock, bubblewrap) need the no_new_privs bit for an unprivileged process,
which stops a setuid program such as sudo from raising rights; only a process with CAP_SYS_ADMIN
may skip it (Landlock documentation patches,
https://kernsec.org/pipermail/linux-security-module-archive/2026-August/058972.html; Claude Code
uses bubblewrap on Linux, https://code.claude.com/docs/it/sandboxing.md,
https://blog.senko.net/sandboxing-ai-agents-in-linux). So a fence and sudo can't run in the same
command. Options were clean-up only, a fence with sudo commands declared and run outside it, or a
plain shell. Chosen: clean-up only (Toni, 2026-10-31).

To check in the plan: stopping what a command started through sudo (it runs as root). Following
each command in its own control group and killing the group (`cgroup.kill`) is the likely way;
whether a user's delegated group can kill root processes in it, and whether sudo moves processes
to another group on some distributions (pam_systemd), is unverified.

## Existing Linux MCP servers (what they offer)

- linux-admin-mcp-server: 14 tools, services, journal, processes; sudo only for service changes
  (https://pypi.org/project/linux-admin-mcp-server).
- RHEL Lightspeed linux-mcp-server: read-only diagnostics, journal, audit log, allowlisted log
  files; an SSH mode for remote hosts
  (https://lobehub.com/mcp/narmaku-linux-mcp-server-archived).

Both run on the server over stdio for a local client; neither reaches Claude's web and phone
apps behind a router, which is what the relay adds. Their service and log tools are the later
"server tools" left out of this spec.

## Constitution wording

Principles I ("The Mac never accepts inbound connections") and IV ("Good macOS citizen") name the
Mac. Approved by Toni, 2026-10-31: I becomes "A paired machine never accepts inbound
connections"; IV gains "and a good Linux citizen: a systemd service, the distribution's own
conventions, sudo set up only by the Owner, an uninstall that leaves nothing"; II and III say "machine" for
"Mac"; VIII allows four projects (below).

## Where the server program's code lives

Chosen: its own Go module, with the protocol package moved out of the relay's internals so both
use it (Toni, 2026-10-31). The relay already has the protocol in Go
(`relay/internal/agentproto`) and a pretend Mac in Go (`relay/internal/testagent`); Go lets
`internal/` packages be used only inside their module, which is why "inside the relay" was the
cheapest first answer.

| Option | For | Against |
|---|---|---|
| Inside the relay's module (second program) | Shares protocol and pretend Mac directly; one build runs both ends; one set of checks | Its module lists the relay's web, sign-in, passkey, and database libraries (not built in, but in every vulnerability report and update); invites assuming both ends share a version though they release apart; only a lint rule keeps relay internals out; endpoint code under `relay/` |
| Own module, shared protocol package | Dependency list holds only what it uses, easier to audit for a program that can run sudo; compiler keeps relay internals out; own version and releases; same separation as the Mac app, held together by the shared example messages (`contracts/fixtures/`) | One more module to build and check, a workspace file; the protocol package becomes public; Constitution VIII says four projects |
| Own module, copied protocol code | Least coupling | Two copies drift; only the fixtures catch it |

The deciding points: the server program's security boundary and release line differ from the
relay's, and the example messages, not shared code, are what already keep the Mac and the relay
compatible.

## Other choices

- The server program is Go (Toni, 2026-10-31); one static file per architecture.
- Reading PDFs and documents on Linux needs a library in Go instead of PDFKit; picked in the plan.
