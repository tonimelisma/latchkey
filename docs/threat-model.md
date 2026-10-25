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
- **B1a Which clients.** By default only clients whose metadata document is on `claude.ai` are
  looked up; any other client ID is refused before any outbound request, and `/register` is off
  unless `ALLOWED_CLIENT_HOSTS=*`. A document on an allowed host can send codes only to an allowed
  host or to loopback. Still true: a program on the Owner's own computer can pose as Claude Code
  (loopback redirect); the Allow page on every sign-in is the control (FR-049a).
- **B1b Operator commands.** They need a shell on the server and the database, which already
  means full control of the relay; they add no network surface. Every command that changes
  something is recorded with who, what, and when. A suspension is enforced in the database,
  which sign-in, tokens, and the Mac's handshake read on every request; open connections follow
  within 2 seconds.
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
  The Files tools refuse changes to the app's own data folder, settings files and bundle
  (spec 003 FR-210); `latchkey://` links are handled one at a time.
  Debug and test builds are a different app to macOS (`net.melisma.latchkey.dev`, spec 001
  FR-074), so a test copy or leftover Debug build has none of the installed app's settings,
  Keychain items, or privacy permissions.
- **B6 Supply chain.** Go modules, Sparkle (pinned by commit), Docker base images, Homebrew-installed tools, the
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
- **Emailed codes are 6 digits with no per-visitor limit** (Toni, 2026-10-25): one account is
  protected by 5 tries per code and 20 wrong codes a day, but guesses spread over many known
  addresses are bounded only by the relay-wide email limit.
- **The daily lock is per email address** (Toni, 2026-10-25): anyone can enter 20 wrong codes for
  an address and block its emailed codes for a day at a time; passkeys still sign in.
- **Shell, when on, can change Latchkey's own files**; only the Files tools refuse that.
- **Each handled pairing link sends one lookup** to the relay it names before the dialog.
- **Processes a command deliberately detaches from its terminal** are not stopped with it.
- **A page that shows a password as plain text** without marking the field is read as text.
- **Pairing links from outside the app's sign-in window** are accepted after a dialog that names
  the relay and the link's account email (Toni, 2026-10-24); not bound by a one-time secret.

- **A whole-disk copy of the server holds the database and its key file together**, so the
  nightly backups protect against loss, not against someone who obtains a backup. Copies made
  before 2026-10-25 hold the old keys unencrypted until they age out after 14 days.
- **The operator's record keeps an account's email address for a year** after the account is
  deleted (FR-199).
- **With built-in HTTPS, certificate keys sit unencrypted in `DATA_DIR/certs`** (not used by the
  hosted relay).

## Invariants that must hold (what a finding violates)

1. Every `/mcp` request is tied to one account by a valid, unexpired, unrevoked access token
   with the connector URL as audience; nothing reaches another account's Mac (A1, A2).
2. Authorization codes need PKCE S256 and a registered redirect URI; codes are single-use;
   refresh-token reuse after the 60 s grace revokes the family; a code presented by two requests
   at once ends the grant; revoking Claude's access kills
   every token of that grant.
3. Consent is shown and approved by a signed-in owner (session cookie plus CSRF token) before
   any code is issued, every time: approvals are not remembered (Toni, 2026-10-25; RFC 8252
   §8.6). The client name and redirect host shown are the ones that will be used. Redirects back to
   the client name the relay as issuer (RFC 9207).
4. Only a device holding the registered Secure Enclave key can act as the Mac; pairing codes are
   single-use, short-lived, and bound to the signed-in account; revocation closes the socket at
   once and the key no longer works. A Mac revoked while connecting is closed as soon as it is
   registered; its signature is verified before anything else it sent is parsed.
5. A capability turned off on the Mac is absent from the tool list and refused if called anyway
   (Constitution III), whatever the relay sends. Turning a capability off or down also stops
   its running calls and, for Shell, its commands with everything they started (FR-066, spec 004
   FR-310, FR-311).
6. Sign-in and recovery codes: 6 digits, hashed, 15 minutes, 5 wrong attempts, rate-limited per
   address and per email; recovery removes old passkeys and is announced. A recovery request
   answers the same, at the same speed, for known and unknown addresses; completing a recovery
   ends every other pending one.
7. The relay never blocks on the Mac without a deadline, and no unauthenticated request can make
   it hold unbounded memory, goroutines, connections, or rows. Bounded: MCP sessions (30 minutes
   idle, 64 per owner), frames from a connected Mac (60 at once, then 5 a second) and its tool
   list (256 tools, 512 KiB), request bodies (30 s; 2 minutes on `/mcp`), cached client documents
   (1,000 unused), pending passkey sign-ins and tickets (10,000 each).
8. The CIMD fetch can reach only public HTTPS addresses, with size and time limits; failures are
   remembered for 5 minutes, and the reason for a failed fetch is never returned.
9. The root helper does exactly two things (sleep on, sleep off) and only for a caller that
   satisfies the app's code-signing requirement. The app connects to the helper only with a
   code-signing requirement (none available means no connection), and Release builds refuse
   peers carrying the debugging entitlement.
10. A `latchkey://` link that doesn't come through the app's own sign-in window is used only
    after the owner confirms a dialog naming the relay's host and the email of the code's account
    (from `/pair/preview`, which doesn't use the code); no Connect button if the lookup fails.
    One link is handled at a time; a link naming an unencrypted relay (http on localhost) is
    accepted only in Debug builds.
11. Tool arguments stay data: no string from Claude is spliced into AppleScript, JavaScript, SQL,
    or a shell command line except where the tool's purpose is to run it (`shell_run`, the
    JavaScript action in `browser_act`), and read-only tools don't change anything.
12. No secret (relay address, server details, team ID, API keys, tokens) is committed, logged, or
    returned in an error. `scripts/private-values-check.sh` enforces the first part (`make
    secrets` and the push guard); the proxy's access log leaves out redirect targets; the app's
    log carries the relay address only as private data.
13. A Read only browser read never returns what password, one-time-code or card fields hold
    (spec 005 FR-410).
14. The Files tools never change Latchkey's own files: activity log, settings (capability
    levels), app bundle (spec 003 FR-210).
15. A copy of the database alone yields neither the token signing key nor the CSRF key: both are
    sealed with AES-256-GCM under a key file kept apart from the database (FR-186 to FR-189).
16. The Owner can see every live approval on the Mac and the account page and remove one. The Mac
    names an approval only by a random public id that is neither a token nor the client ID, and
    the relay removes it only for the Mac's own account (FR-190 to FR-192).

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
