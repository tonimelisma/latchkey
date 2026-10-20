# CLAUDE.md — Latchkey

Read this first. It is the handover document: anyone (human or agent) picking up this repo should
be able to continue from here without the original conversation.

**Keep this file current.** Whenever the status, a decision, the process, or an open question
changes, update this file in the same commit. If this file and a spec disagree, the spec wins for
WHAT/HOW and this file must be fixed.

## What Latchkey is

Your Mac, at Claude's fingertips from anywhere. Install one Mac menu bar app, sign in with a
passkey, paste one link into Claude, and Claude on the web, Desktop, iOS and Android can use your
Mac, even when it sits behind a home router. When the Mac is asleep, out of battery or off, Claude
is told immediately and why, instead of hanging.

- Free and open source. A hosted relay for everyone, and anyone can self-host it.
- One Mac per user. Apple silicon only. Current and previous major macOS release.
- Owner: Toni Melisma (GitHub `tonimelisma`).

## How it works (one paragraph)

The Mac app opens an outbound WebSocket to the relay (this is the NAT traversal: no ports, no
router setup, no third-party tunnel). The relay is a Go server with SQLite at a stable public HTTPS
URL; it is the MCP server that Claude connects to as a custom connector. The relay handles OAuth
sign-in, remembers the Mac's state (online, last seen, battery, thermal, keep-awake), always answers
`laptop_status` and the tool list, and forwards real tool calls to the Mac with a deadline. If the
Mac is offline or slow, Claude gets a clear error within seconds. A privileged helper (via
`SMAppService`) keeps the Mac awake even with the lid closed on battery, and lets it sleep at 15%
battery or when too hot, reporting why.

## Where things are

| Path | What |
|---|---|
| `memory/constitution.md` | Nine non-negotiable principles. Every plan is checked against them. |
| `specs/001-core/spec.md` | WHAT and WHY: user stories, requirements (FR-xxx), success criteria (SC-xx). No tech. |
| `specs/001-core/plan.md` | HOW: architecture, decisions D1–D11 traced to requirements, layout, tests, milestones. |
| `specs/001-core/research.md` | Evidence and sources behind the plan, including rejected alternatives. |
| `specs/001-core/data-model.md` | Everything the relay stores, and what it never stores. |
| `specs/001-core/contracts/agent-protocol.md` | Mac app ↔ relay WebSocket protocol v1. |
| `specs/001-core/contracts/mcp-surface.md` | What Claude sees: endpoints, OAuth metadata, tools, error texts. |
| `relay/` | (not yet created) Go relay. |
| `macos/` | (not yet created) Xcode project: menu bar app + helper daemon. |

## Current status

- Phase: spec 001 written and reviewed; no code yet.
- Next: (1) `specs/001-core/tasks.md`; (2) milestone **M0**, the keep-awake spike on real
  hardware, because the whole design depends on it (see risks).
- Milestones (plan.md): M0 keep-awake spike → M1 relay hub + agent protocol with a Go test agent →
  M2 Mac app connects and answers `battery_status` → M3 OAuth, passkeys, pairing → M4 end to end
  from Claude on phone, web, Desktop → M5 signing, notarization, Sparkle, Docker image.

## Development process (spec-driven)

Adapted from GitHub Spec Kit. Lightweight on purpose: one spec folder per capability, small
contracts, tests on the contracts.

1. **Constitution** (`memory/constitution.md`). Changes rarely and only with Toni's explicit approval.
2. **Specify**: `specs/NNN-name/spec.md`. What and why only. Requirements in EARS form ("When X,
   the system shall Y"), stable IDs that are never renumbered (add new IDs, mark removed ones as
   withdrawn). Success criteria are measurable and technology-free.
3. **Clarify**: anything undecided is marked `[NEEDS CLARIFICATION: ...]`, never guessed. Resolve
   them with Toni (see working with Toni) and record the answer in the spec.
4. **Plan**: `plan.md` (+ `research.md`, `data-model.md`, `contracts/`). Every decision names the
   requirements it serves. Finish with the constitution check table.
5. **Tasks**: `tasks.md`, ordered, each task testable, parallel-safe tasks marked `[P]`.
6. **Implement test-first**: contract and integration tests are written and seen failing before
   the code (Constitution VII). Integration tests use a real MCP client, not mocks.
7. **Keep specs alive**: any change in behavior updates the spec, plan or contract in the same
   commit as the code. Specs must never drift from the code.

New capabilities (files, Notes + iMessage, shell, browser and computer control) each get their own
`specs/NNN-name/` and their own design discussion with Toni, one at a time, in that order.

### Git

- Remote: private GitHub repo `tonimelisma/latchkey`. Default branch `main`.
- Branch per spec or task: `NNN-short-name` (for example `001-core`, `002-files`).
- Small commits; specs and code change together. Open PRs only when asked.

## Working with Toni

- Explain in plain, short language. Avoid jargon; when a term is unavoidable, say what it does.
- Toni wants complete solutions, not partial matches. Say plainly when something doesn't fully meet
  a requirement.
- Decisions go to Toni as multiple-choice questions with a recommended, sane default first. Don't
  re-ask decided questions (see decision log).
- Lead with the answer; skip long surveys of options you won't pursue.

## Decision log (approved by Toni)

| Area | Decision |
|---|---|
| Audience | A product for others from day one; free and open source (MIT or Apache-2.0) |
| Machines | One Mac per user; Apple silicon only; current + previous macOS |
| NAT traversal | Mac app's own outbound WebSocket to the relay. No cloudflared, ngrok, or Tailscale |
| Relay | Go, SQLite only, single server first, Docker, self-hostable |
| Relay role | Speaks MCP itself (handshake, cached tool list, `laptop_status` offline); forwards only tool calls |
| Relay memory | Online/last seen, battery/power/thermal/keep-awake state, audit log (metadata only, 30 days). No request queueing |
| Mac-side log | Full trace with arguments and results, local only, 90 days by default |
| Privacy | Encrypted in transit is enough; relay never stores tool results |
| Claude auth | OAuth 2.1 as Claude connectors require: fosite + our own CIMD and DCR client lookup |
| Owner login | Passkeys only (go-webauthn); recovery by single-use email link (SMTP) |
| Claude setup | Custom connector URL now; Anthropic connector directory later |
| Mac app | Native Swift menu bar app, notarized direct download, Sparkle updates; no App Store |
| Keep-awake | Always on, lid closed and on battery too, via an `SMAppService` privileged helper over XPC (a "good macOS citizen": no CLI, no sudoers) |
| Low battery | Fixed 15%: report, turn keep-awake off, let it sleep |
| Too hot | Thermal state serious/critical: report, let it sleep |
| Recovery | Keep-awake re-enables automatically when safe |
| Permissions | User picks capabilities in the app; disabled = invisible to Claude. Per-call approval is left to the Claude apps |
| First tool | `battery_status` (hello world), then files |
| Times | Offline messages use the Mac's reported time zone |
| Access logs | Relay web access logs (IPs) kept 30 days |
| Legal | Terms and privacy policy deferred; launch blocker for the hosted relay |
| Apple Developer ID | Toni will get one; build with Apple Development signing until then |
| Name | Latchkey |

## Open questions and risks

- **Risk (highest): lid-closed keep-awake on Apple silicon.** `pmset disablesleep` is the only
  mechanism that prevents clamshell sleep; reports conflict about whether it survives charger
  plug/unplug. M0 tests this on real hardware before anything else is built.
- Domain for the hosted relay: not chosen.
- Claude's hosted-client tool-call timeout is undocumented: measure in M4, keep our deadline cap
  (60 s) below it.
- Whether `SMAppService` daemons run with free Personal Team signing: verify in M0.
- Terms, privacy policy, abuse handling: launch blocker, deferred.

## Key external facts (verified 2026-10, see research.md for sources)

- Claude custom connectors are called from Anthropic's cloud (egress `160.79.104.0/21`), not from
  the user's device. The server needs a public HTTPS URL. Added once on claude.ai, a connector
  appears on all Claude surfaces.
- Claude's OAuth client: needs `401` + `WWW-Authenticate: Bearer resource_metadata=...`; uses only
  the first `authorization_servers` entry; uses CIMD only if `client_id_metadata_document_supported`
  is true and `none` is a token auth method, else DCR; PKCE S256; callback
  `https://claude.ai/api/mcp/auth_callback`; Claude Code uses loopback redirects on any port; 10 s
  limit on discovery/registration/token endpoints, 30 s on refresh; refresh errors must be
  `invalid_grant`; no `client_credentials`.
- Cross-host redirects drop the `Authorization` header in Claude's hosted runtime.
- MCP spec 2026-07-28 is stateless (no `initialize`); Claude's hosted runtime still sends
  `initialize` as of mid-2026. Support both (the Go SDK does).
- Anthropic's own MCP tunnels are Enterprise-only and not an option here.

## Commands

None yet. Add build, test, and run commands here as soon as `relay/` and `macos/` exist.
