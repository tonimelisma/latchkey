# Latchkey threat model

Written 2026-10-24 before the first whole-repository security scan (Toni chose: threat model
first, then Anthropic's Claude Security scanner, findings proven with a failing test before they
are fixed). Scanners and reviewers read this file; keep it current when an entry point, trust
boundary, or decision changes. Design detail lives in `specs/001-core/plan.md` and the capability
specs; best-practice review and gaps in `docs/best-practices.md`.

## What is being protected

1. **Control of the owner's Mac.** With Shell and Computer control on (the default), anyone who
   can make the relay forward a tool call runs commands as the owner. This is the crown jewel;
   everything else is a path to it.
2. **The owner's data** returned by tools: notes, messages, files, browser pages, screenshots.
   It passes through the relay in plaintext (the relay stores none of it).
3. **Accounts and credentials:** passkeys, web sessions, sign-in and recovery codes, OAuth access
   and refresh tokens, client registrations, the Mac's Secure Enclave device key, the relay's
   HMAC token secret, SMTP and DNS API keys in `.env`.
4. **Availability:** the Mac staying awake and reachable; the relay answering at once when it
   isn't (Constitution II: never wait on the Mac without a deadline).

## Components and trust boundaries

```
Claude (Anthropic cloud) ──HTTPS, OAuth bearer──▶ Relay (Go, SQLite, behind Caddy, one VM)
Owner's browser ─────────HTTPS, session cookie──▶   │  account pages, passkeys, pairing
                                                    │
Mac app ◀──────WSS, outbound, device-key signature──┘
   │  XPC (code-signing requirement)
   └─▶ Helper daemon (root): pmset disablesleep 1|0 only
```

Boundaries, each a place where input must be treated as hostile:

- **B1 Internet → relay HTTP.** Every route in `relay/internal/oauth/oauth.go`,
  `relay/internal/account/account.go`, and `relay/internal/server/server.go`: OAuth discovery,
  `/register` (DCR), `/authorize` (consent), `/token`, `/revoke`, `/mcp`, sign-in (`/auth/email`,
  `/auth/code`), passkeys (`/passkey/*`), `/account*`, `/pair`, `/pair/preview`, `/pair/exchange`, `/agent/v1`,
  `/static/`, `/healthz`.
- **B2 Relay → the outside world.** Client ID Metadata Documents: the relay fetches an HTTPS URL
  the client chooses (SSRF risk). Outbound email through SMTP (header injection).
- **B3 Relay ↔ Mac.** The agent protocol (`specs/001-core/contracts/agent-protocol.md`): nonce
  challenge signed by the device key, then tool lists, calls, results, state, notices. The Mac
  must not trust the relay beyond it: capability levels are enforced on the Mac.
- **B4 Tool arguments → macOS.** Arguments from Claude become shell commands, file paths,
  AppleScript, JavaScript run in Safari, SQLite queries on Messages and Notes databases, and
  synthesized input events. By design they act with the owner's full rights when the capability
  is on; the bug class is a tool doing *more or other* than its arguments say (escaping out of
  AppleScript or JavaScript string literals, a "read" tool that writes, a turned-off capability
  still reachable).
- **B5 Other local processes → the app and helper.** The helper's Mach service, the
  `latchkey://` URL scheme, the app's files in Application Support (activity log with full
  tool arguments and results, AES-GCM encrypted with a key in the Keychain, FR-026a), user defaults, Keychain items.
- **B6 Supply chain.** Go modules, Sparkle, Docker base images, Homebrew-installed tools, the
  deploy and install scripts, the update feed.

## Attackers in scope

| | Attacker | Wants | Main paths |
|-|-|-|-|
| A1 | Anyone on the internet | Run tools on someone's Mac; take over an account | B1: forge or steal tokens or sessions, skip consent, bypass PKCE or redirect checks, brute-force codes, reuse refresh tokens, hijack pairing, impersonate a Mac on `/agent/v1`, flood to deny service |
| A2 | Another account on the same relay (self-hosters may open sign-up) | Reach a Mac or data that isn't theirs | B1/B3: cross-account access to MCP servers, tool calls, devices, grants, audit rows, revocations |
| A3 | A malicious OAuth client | Get a token for the owner's Mac | B1/B2: phishing redirect URIs, consent confusion (name or host shown), CIMD documents pointing at internal addresses, registration flooding |
| A4 | A process running as another user, or unprivileged, on the Mac | Root, or the owner's data | B5: talk to the root helper, spoof the code-signing check, inject a `latchkey://` link that pairs the Mac with an attacker's relay, read the activity log |
| A5 | Network attacker between Mac or Claude and the relay | Read or alter traffic | TLS everywhere; plain HTTP accepted only on localhost; device-key signature on the Mac's connection |
| A6 | Supply chain | Code execution in the relay, app, or build | B6: vulnerable or malicious dependency, unsigned update, secret in the repository or image |

## Accepted risks (decided; scanners should not report these as findings)

- **A compromised relay or relay operator can call any capability that is on**, and read tool
  traffic. No end-to-end layer exists for custom connectors today (`docs/best-practices.md` §4);
  Shell and Computer control stay on by default (Toni, 2026-10-22).
- **Prompt injection** through tool results (web pages, messages, files): out of scope, Toni
  2026-10-23. No Latchkey-side injection defenses.
- **No per-call approval on the Mac** ("manual approvals don't improve security", Toni
  2026-10-23). Opening pages in Safari stays automatic; `messages_send` sends without a
  Latchkey-side stop when Claude was asked to.
- **Tools act with the owner's full rights when on.** Shell runs any command; Files reads and
  writes anywhere the owner can. That is the feature, not a bug.
- **Remembered consent covers Claude Code too** (Toni, 2026-10-24): once the owner approved a
  client, a later sign-in with the same client and a loopback redirect on any port is approved
  without asking, so a program on the owner's computer posing as that client gets a token.
- **Pairing links from outside the app's sign-in window** are accepted after a dialog that names
  the relay and the link's account email (Toni, 2026-10-24); not bound by a one-time secret.

## Invariants that must hold (what a finding violates)

1. Every `/mcp` request is tied to one account by a valid, unexpired, unrevoked access token
   with the connector URL as audience; nothing reaches another account's Mac (A1, A2).
2. Authorization codes need PKCE S256 and a registered redirect URI; codes are single-use;
   refresh-token reuse after the 60 s grace revokes the family; revoking Claude's access kills
   every token of that grant.
3. Consent is shown and approved by a signed-in owner (session cookie plus CSRF token) before
   any code is issued; the client name and redirect host shown are the ones that will be used.
4. Only a device holding the registered Secure Enclave key can act as the Mac; pairing codes are
   single-use, short-lived, and bound to the signed-in account; revocation closes the socket at
   once and the key no longer works.
5. A capability turned off on the Mac is absent from the tool list and refused if called anyway
   (Constitution III), whatever the relay sends.
6. Sign-in and recovery codes: 6 digits, hashed, 15 minutes, 5 wrong attempts, rate-limited per
   address and per email; recovery removes old passkeys and is announced.
7. The relay never blocks on the Mac without a deadline, and no unauthenticated request can make
   it hold unbounded memory, goroutines, connections, or rows.
8. The CIMD fetch can reach only public HTTPS addresses, with size and time limits.
9. The root helper does exactly two things (sleep on, sleep off) and only for a caller that
   satisfies the app's code-signing requirement.
10. A `latchkey://` link that doesn't come through the app's own sign-in window is used only
    after the owner confirms a dialog naming the relay's host and the email of the code's account
    (from `/pair/preview`, which doesn't use the code); no Connect button if the lookup fails.
11. Tool arguments stay data: no string from Claude is spliced into AppleScript, JavaScript, SQL,
    or a shell command line except where the tool's purpose is to run it (`shell_run`, the
    JavaScript action in `browser_act`), and read-only tools don't change anything.
12. No secret (relay address, server details, team ID, API keys, tokens) is committed, logged, or
    returned in an error.

## Where to look first

Ordered by how directly an outside attacker reaches the crown jewel:

1. `relay/internal/oauth/` (tokens, consent, clients, CIMD fetch) and `relay/internal/server/`
   (`perUser`, guards, limits).
2. `relay/internal/hub/` and `relay/internal/agentproto/` (device authentication, routing calls to
   the right Mac, deadlines) and `macos/App/RelayConnection.swift`, `AgentProtocol.swift`,
   `DeviceIdentity.swift`, `Pairing.swift`.
3. `relay/internal/account/` and `relay/internal/store/signin.go` (sign-in codes, passkeys,
   sessions, CSRF, pairing, revocation, deletion).
4. `relay/internal/mcpserver/` (per-account servers, tool sync, result handling).
5. `macos/App/Capabilities.swift` and each capability folder (level enforcement, argument
   escaping in AppleScript and page scripts, SQLite queries).
6. The helper and its XPC check; `macos/App/Installation.swift`; the URL scheme handler.
7. Scripts and deployment: `deploy/`, `macos/scripts/`, `scripts/`, the container settings.
