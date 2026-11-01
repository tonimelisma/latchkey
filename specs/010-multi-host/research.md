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

Stopping what a command started through sudo (it runs as root): each command runs in its own
control group under the service's delegated one, and the group is killed with `cgroup.kill`.
Verified on Debian 12 with systemd (2026-11-01, `make test-linux` and the end-to-end check): the
processes sudo starts stay in the job's group, and `cgroup.kill` written by the service's own
(unprivileged) user stops root's processes in it, since the kernel applies it to every process in
the group without the usual permission check. Distributions whose sudo goes through pam_systemd
(it may start a new session scope) are unverified; there a root leftover might escape. Kernels
before 5.14 have no `cgroup.kill`; the program then signals each process, and another user's
processes may stay.

Found while testing (2026-11-01): a leftover that keeps the terminal open (its standard input)
kept the job "running" for ever, because the job's end was the terminal closing; the end is now
the command's own process exiting. And a plain `cmd &` usually dies with bash anyway: when the
terminal's session leader exits, the kernel sends the terminal's process group a hang-up.

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
- PDF text: `github.com/ledongthuc/pdf` (BSD, the Go Authors' license; a maintained fork of
  `rsc.io/pdf` with plain-text extraction), over `rsc.io/pdf` (no text API) and calling
  `pdftotext` (a package the server may not have). Terminal: `github.com/creack/pty` (MIT).
  Details in contracts/server-program.md.

## End to end: how Claude uses several machines

Asked by Toni, 2026-10-31, before the shared tools' shape was chosen.

- Claude's apps cache the tool list and don't reliably refresh it
  (https://github.com/anthropics/claude-ai-mcp/issues/137,
  https://help.usewheelhouse.com/en/articles/15908885-refreshing-your-claude-connector-to-get-new-tools);
  with many connectors claude.ai may load tool names first and definitions on demand
  (https://support.claude.com/articles/11176164-use-connectors-to-extend-claude-s-capabilities).
  So the list must not depend on which machines are online, and each description must say how to
  pick a machine.
- MCP's `instructions` at initialize (https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle.md)
  are loaded by Claude Code (https://code.claude.com/docs/de/mcp-quickstart.md); other hosts have
  been reported to ignore them (https://www.blog.blockscout.com/mcp-explained-part-8-server-instructions).
  Useful, not to be relied on.
- Live facts belong in answers: a cheap list tool plus an optional target argument with a default
  is the common pattern for one server with many targets
  (https://glama.ai/mcp/servers/@salacoste/mcp-n8n-workflow-builder/blob/db31e85c7f33f9254946d9a8dcf06a71fcbeb675/docs/multi-instance/instance-routing.md),
  with descriptions saying when to list and when to name the target
  (https://glama.ai/mcp/servers/featureflow/featureflow-mcp/tools/list_environments), and
  errors that say how to fix the call (https://www.anthropic.com/engineering/writing-tools-for-agents).

Chosen by Toni, 2026-10-31: one tool per name with "On a Mac: …" / "On a Linux server: …" parts
(only the kinds paired), the argument named `machine`, a relay tool `machines`, and every answer's
state line followed by the other machines.

## Security reviews while building (2026-10-31)

The automatic review of each commit found, and the build fixed:

| Finding | Fix |
|---|---|
| A Linux server could ask to remove a Claude app's access | `clients` and `revoke_client` for Macs only (4005 otherwise) |
| A link carrying the pairing code allowed a one-click approval of someone else's machine | No `verification_uri_complete`; the code is typed; the page shows when it was asked and that the machine chose its name |
| Name uniqueness and naming a machine in a call compared differently | One key, `store.NameKey`: Unicode simple case folding |
| A link to a not-yet-existing file in Latchkey's folders passed the own-files check | A final link is followed to its target before the check |
| A huge picture could exhaust memory | Over 50 megapixels refused before decoding |
| The PDF parser can panic | Recovered in the reader and in the call dispatcher |
| A command could start just after Shell was turned off | Shell's own switch, checked under the start lock (FR-1034) |
| An old signed program could be published under a newer tag | The signature covers version and architecture (FR-1029) |

Left as is, with the reason: a file swapped by another program between Files' own-files check and
the change (Shell, which has no write fence on a server, can change these files anyway).
