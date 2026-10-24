# Research 001

Evidence behind `plan.md`, gathered 2026-10-18 to 2026-10-19. Re-check anything marked
"unverified" before relying on it.

## Method: spec-driven development

- Adopted a lightweight form of GitHub Spec Kit's layout: constitution, then spec (what and why),
  plan (how), research, data model, contracts, and tasks per feature folder. Spec Kit also marks
  open questions with `[NEEDS CLARIFICATION]` instead of guessing, and checks plans against the
  constitution. https://github.com/github/spec-kit/blob/main/spec-driven.md
- Requirements use EARS-style sentences ("When <trigger>, the <system> shall <response>"), which
  make missing triggers and vague responses easier to spot. https://www.braingrid.ai/blog/ears-notation
- Known criticism: heavy spec processes become markdown bureaucracy and drift from code. Mitigation
  here: one spec per capability, contracts kept small and tested, and specs updated in the same
  change as code. https://feedbagel.com/post/critique-of-spec-driven-development-balancing-structure-and-agility-in-ai-progra
- Tool landscape (Spec Kit, Kiro, OpenSpec, Tessl): https://ssojet.com/blog/best-spec-driven-development-tools

## How Claude reaches MCP servers

- Custom connectors: Claude connects from Anthropic's cloud, not the user's device. The server must
  be reachable on the public internet over HTTPS. https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp
- Anthropic outbound IP range: `160.79.104.0/21`. https://platform.claude.com/docs/en/api/ip-addresses
- Connectors added on the web appear on mobile; adding them on mobile is in beta.
  https://support.claude.com/en/articles/11176164-use-connectors-to-extend-claude-s-capabilities
  and https://v3.developers.enapter.com/docs/claude-mobile-mcp
- OAuth requirements (401 + `resource_metadata`, first `authorization_servers` entry only, CIMD
  conditions, PKCE S256, callback URL, loopback for Claude Code, 10 s / 30 s endpoint limits,
  form-urlencoded token endpoint, `invalid_grant`, refresh rotation, no `client_credentials`):
  https://claude.com/docs/connectors/building/authentication.md
- Static header credentials are a limited beta for organizations, so OAuth is the only reliable
  option for personal accounts. Same source.
- Hosted runtime: Streamable HTTP; drops `Authorization` on cross-host redirects; still uses
  `initialize` (2026-07-28 support rolling out). https://zuplo.com/learn/mcp/compatibility/clients/claude-connectors.md
- Claude Code CIMD redirect issue (community report): https://github.com/anthropics/claude-code/issues/37747

## Alternatives rejected for NAT traversal

- Anthropic MCP tunnels: Enterprise or Console organizations only, research preview, not for
  consumer claude.ai. https://claude.com/docs/connectors/mcp-tunnels/overview.md
- Claude Desktop relay (Cowork, Dispatch): requires the Desktop app open, works only in Cowork, and
  docs are unclear whether phone-started sessions reach local MCP servers.
  https://support.claude.com/en/articles/15520349-use-claude-cowork-on-web-desktop-and-mobile
- Per-user Cloudflare Tunnel, ngrok, Tailscale Funnel: extra hop, per-user provisioning, vendor
  dependency, and a relay is still needed for the stable URL, OAuth, and offline answers.

## MCP protocol

- 2026-07-28 removes the `initialize` handshake and sessions; older versions remain supported under
  a 12-month deprecation policy. https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/
- Go SDK v1.7+ supports 2026-07-28 (stateless mode via `StreamableHTTPOptions.Stateless`).
  https://github.com/modelcontextprotocol/go-sdk/releases
- Go SDK `auth` package: `RequireBearerToken`, `ProtectedResourceMetadataHandler`, 401 with
  `WWW-Authenticate`. No authorization server included. https://pkg.go.dev/github.com/modelcontextprotocol/go-sdk/auth

## Libraries

- go-webauthn: BSD-3, still v0 (breaking changes possible), supports usernameless login.
  https://github.com/go-webauthn/webauthn
- fosite: Apache-2.0, used by Ory Hydra; maintenance status not directly confirmed (unverified).
- Go OAuth alternatives considered: forge-oauth (CIMD, pre-1.0), authlet (GPL-3, license
  conflict), mcp-kit (pre-1.0). https://pkg.go.dev/forge-cms.dev/forge-oauth,
  https://pkg.go.dev/github.com/eliminyro/authlet, https://pkg.go.dev/github.com/haakco/mcp-kit
- wneessen/go-mail, coder/websocket, modernc.org/sqlite: chosen from general knowledge (unverified
  in this round).

## Keep-awake on macOS

- Power assertions (`caffeinate`, Amphetamine, KeepingYouAwake) prevent idle sleep but not lid-close
  sleep; `pmset disablesleep` does. Sleepless (MIT) uses it and reports it working on macOS 26.3
  Apple silicon. https://github.com/Aboudjem/Sleepless
- Conflicting reports that it fails on Apple silicon when the power source changes; Amphetamine
  added a "Power Protect" script for exactly that case. https://mac.softpedia.com/progChangelog/Amphetamine-Changelog-140109.html
  and https://pasqualepillitteri.it/en/news/779/disable-laptop-sleep-lid-close-ai-agents
- Conclusion: re-apply on every power change and wake, and read back to verify. (A hardware spike
  was planned, then dropped by Toni on 2026-10-20.)

## macOS packaging

- SMAppService daemons must be signed like the parent app or they may not run.
  https://developer.apple.com/forums/thread/757463
- Sparkle 2: Developer ID signing plus EdDSA-signed archives. https://sparkle-project.org/documentation/
- Free Personal Team signing for SMAppService daemons during development: unverified.

## Existing projects reviewed

- remote-control-mcp (Mac over tunnel + OAuth, iOS demo): https://glama.ai/mcp/servers/Hexpy-Games/remote-control-mcp
- Apple app servers for later specs: apple-mcps, mac_messages_mcp, imessage-mcp, macnotes-mcp.
- Computer use for later specs: Peekaboo, trycua/cua, mcp-server-macos-use.
  https://pinggy.io/amp/blog/best_computer_use_mcp_servers/

## Relay listen address and port (decided 2026-10-20)

- Address: all interfaces, as Toni proposed (`0.0.0.0`). In Go that is written `":8080"`, which
  also covers IPv6; a literal `0.0.0.0:8080` would be IPv4 only. Inside a container this is
  required: listening on `127.0.0.1` is unreachable from outside the container.
- Port: read the `PORT` environment variable, default 8080. `PORT` is the de facto convention that
  hosting platforms inject (Cloud Run always sets it, default 8080; Fly.io's default internal port
  is 8080). 8080 rather than 80 or 443 because the container runs as non-root, and ports under
  1024 need root or an extra Linux capability.
- ACME: Go's `autocert` validates over TLS-ALPN-01 (public port 443) or HTTP-01 (public port 80).
  The process can listen on any local port as long as public 443 is forwarded to it, so built-in
  TLS uses the same single port. A TLS-terminating proxy in front breaks TLS-ALPN-01; that setup
  uses plain HTTP instead.
- Options not taken: a separate `LISTEN_ADDR` (host and port) variable, which adds a setting
  nobody needs in a container; and serving on 80 and 443 directly, which needs root.

Sources: https://docs.cloud.google.com/run/docs/configuring/services/containers,
https://fly.io/blog/fly-friday-flyctl-and-ports.md, https://env.dev/variables/PORT,
https://go.googlesource.com/crypto/+/56440b844dfe139a8ac053f4ecac0b20b79058f4%5E%21/

## Agent signature encoding (decided 2026-10-20)

Options for `hello.signature`:
- **ASN.1 DER** (chosen): the standard ECDSA encoding. One call on each side (Go
  `ecdsa.VerifyASN1`, CryptoKit `.derRepresentation`). Variable length (70 to 72 bytes), which
  doesn't matter here.
- Raw r||s (64 bytes, JWS ES256 style): fixed length, but Go needs hand-written splitting into two
  big integers, and a wrong-length input is one more case to handle.
- A JWS/JWT token: self-describing, but adds a library and a format for a single signature.

Base64url without padding, matching common practice (JWS) and avoiding `=` handling.

## How others keep a Mac awake, and the right way for the lid-closed case (2026-10-20)

- Claude Desktop's "Keep awake" and Claude Code run `caffeinate` (a power assertion). Desktop
  first used `caffeinate -d`, which also blocked display sleep; users asked for `-i`.
  https://claudeissues.com/issue/36872-claude-desktop-keep-awake-should-not-prevent-display-sleep,
  https://forum.cursor.com/t/option-to-enable-caffeinate-spawning-or-similar-for-other-oses/165844
- Apple's SDK header (IOPMLib.h, `kIOPMAssertPreventUserIdleSystemSleep`): "The system may still
  sleep for lid close, Apple menu, low battery, or other sleep reasons." So assertions cover the
  lid-open case only. `kIOPMAssertionTypePreventSystemSleep` is deprecated and unsupported.
- Lid closed: no public API. `/usr/bin/pmset disablesleep` imports `IOPMSetSystemPowerSetting`
  (exported by IOKit, not in the public headers) and sets `SleepDisabled`, which `ioreg` shows as a
  property of `IOPMrootDomain`. It is not in `/Library/Preferences/com.apple.PowerManagement.plist`
  on this Mac, so it is kernel runtime state and does not survive a restart (inference; not
  tested). Amphetamine needs a separate privileged script ("Power Protect") for the same case.
  https://mac.softpedia.com/progChangelog/Amphetamine-Changelog-140109.html
- Choice: lid open, the public assertion that lets the display sleep (as Claude does); lid
  closed, the helper runs Apple's `pmset` rather than calling the undeclared function
  (Constitution IV). The app verifies by reading `SleepDisabled` from `IOPMrootDomain`, a public,
  unprivileged IORegistry read, instead of parsing `pmset` output.

## Email provider for the hosted relay (2026-10-20)

Mailgun (already in use) allows one domain on its plan, taken by walkbikewc.com. Compared:
- **Resend (chosen):** SMTP with the API key as password (no relay code change); domains and DNS
  records by API; official MCP server; free 3,000 emails/month, 100/day.
- Postmark: best deliverability; manual account approval before sending to outside addresses.
- Amazon SES: cheapest; sandbox exit and AWS setup.
- Cloudflare Email Sending: public beta, Workers paid plan, no SMTP found (would need new code).
Sources: https://dev.to/northloopworks/i-compared-7-transactional-email-apis-so-you-dont-have-to-2026-pricing-5912,
https://chatforest.com/reviews/resend-mcp-server/,
https://developers.cloudflare.com/changelog/post/2026-04-16-email-sending-public-beta/

## Confirming pairing links from outside the sign-in window (FR-054, 2026-10-24)

Toni chose a confirmation dialog naming the account over binding each pairing to a one-time
secret. Implementation details decided here:
- How the app learns the email: a new `POST /pair/preview` that looks the code up without using
  it (chosen), versus putting the email in the `latchkey://` link (rejected: anyone can write any
  email into a link they craft; only the relay knows whose code it is), or using the code at
  `/pair/exchange` first and asking afterwards (rejected: that already replaces the account's
  current Mac). Same expired-code answer for unknown, used, and expired codes, so the endpoint
  says nothing beyond what holding a valid code already gives; covered by the pairing endpoints'
  existing per-address limit (the `/pair` prefix).
- Links while the sign-in window is open: also confirmed (they may come from another browser);
  confirming cancels the open sign-in window. A link carrying the code the sign-in window itself
  just delivered is ignored, so a browser that also hands it to the app shows no "expired" alert.
- Whose word the email is: the relay's. A link can name any relay, and a relay the attacker runs
  can claim any email, the Owner's included. So the dialog's title names the relay (what the
  link controls), the email is shown as "<relay> says this is the account <email>", and a relay
  other than the paired one (or, unpaired, the suggested hosted one) is called out
  (automated review of the first version, 2026-10-24).
- The email shown must be one plain address (no spaces or line breaks, at most 254 characters);
  anything else counts as a failed lookup, so a relay can't put misleading text in the dialog.

## Encrypting the activity log (FR-026a, 2026-10-24)

- Cipher: CryptoKit AES-256-GCM with one random key (chosen: Apple's own, authenticated, no
  dependency), versus SQLCipher for the whole database (rejected: a C library and a SwiftData
  replacement), versus a key derived from the Secure Enclave device key (rejected: the device key
  is deleted on Disconnect, which would lose the log, and it is out of this change's scope).
- What is sealed: everything but the entry's time and a random ID (tool name, arguments, result,
  outcome, duration as one JSON blob). The time stays plain so the 90-day purge is one query.
- Key storage: a generic-password item in the login Keychain through the existing `Keychain`
  helper (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). The app isn't sandboxed and has no
  keychain-access-group entitlement, so the item lives in the file-based login keychain, whose
  default access list trusts only the creating app: another program asking for it makes macOS
  prompt the Owner. The data-protection keychain would bind it to the app's signature without a
  prompt option, but needs an access-group entitlement (signing settings, not changed here).
- Existing plaintext entries: encrypted into a new file once, then the old file deleted (chosen),
  versus deleting them (loses up to 90 days of the Owner's history), versus encrypting them in
  place (rejected: SQLite keeps old plaintext in free pages and its write-ahead log, so the old
  file must go anyway). If the old file can't be read it is deleted all the same.
