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

## Trusted proxies for the hosted relay (2026-10-24, security scan)

FR-082: the relay believes `X-Forwarded-For` only from a loopback peer or a peer listed in
`TRUSTED_PROXIES` (IP addresses and CIDR ranges). The hosted relay sits behind Caddy in another
container on the external docker network `reverse_proxy`, so Caddy's address must be listed. Caddy
replaces a client-supplied `X-Forwarded-For` unless the client is one of its own trusted proxies,
so the rightmost entry is the real client. How the deploy learns Caddy's address:

- **Read the network's subnets on the VM at deploy time (chosen).** `deploy.sh` runs
  `docker network inspect reverse_proxy` over SSH and writes every IPAM subnet (IPv4, and IPv6 if
  the network has it) into `TRUSTED_PROXIES`, refusing to deploy if the answer is empty or not
  addresses. Survives Caddy restarts and address changes; nothing is hard-coded in the
  repository. Cost: every container on that network is trusted, not just Caddy; they are the
  operator's own services on a private bridge, and at worst one could pick its own rate-limit key.
- Caddy's current container address: narrowest, but docker assigns it at start, so a Caddy
  restart between deploys would silently break per-client limits (every client sharing Caddy's
  bucket).
- A fixed subnet or a static Caddy address in compose: robust, but the network and Caddy belong
  to `/opt/reverse-proxy`, outside this repository; changing them touches other services.
- Trust every private address (the old behavior): with `docker run -p` and the userland proxy,
  internet clients over IPv6 arrive from the bridge gateway's private address and could spoof
  their address (scan finding).

Sources: https://caddyserver.com/docs/caddyfile/directives/reverse_proxy#defaults,
https://docs.docker.com/reference/cli/docker/network/inspect/

## Which clients may ask for access (FR-180 to FR-185, 2026-10-25)

Toni chose "Claude only" out of the box. What Claude's apps present, checked on 2026-10-24 by
fetching the documents:

- Web, Desktop, mobile, Cowork: client ID `https://claude.ai/oauth/mcp-oauth-client-metadata`,
  name "Claude", one redirect URI, `https://claude.ai/api/mcp/auth_callback`.
- Claude Code: client ID `https://claude.ai/oauth/claude-code-client-metadata`, name "Claude
  Code", redirect URIs `http://localhost/callback` and `http://127.0.0.1/callback`.
- Both say `token_endpoint_auth_method: none`. Claude uses the document whenever the relay
  advertises `client_id_metadata_document_supported: true` and `none`, and falls back to
  registering itself otherwise.

So one host, `claude.ai`, covers every Claude app, both as the document's host and as the only
non-loopback redirect host. Choices made (low-level; Toni decided the behaviour):

- **What the list matches.** The client ID's host and every non-loopback redirect URI's host
  (chosen): a document on a listed host can't hand codes to another site. Claude's own docs allow
  a server to "require non-loopback redirect_uris to share the client_id URL's origin"; matching
  the list instead of the origin is the same idea and also lets an operator list two hosts.
  Rejected: matching only the client ID's host (an allowed host with an open redirect or user
  content could publish a document pointing elsewhere).
- **How hosts compare.** Exact, after lowercasing and IDNA ASCII conversion (chosen); no
  subdomain wildcards, no trailing dot, port ignored, user-info refused. Wildcards were rejected:
  `*.example.com` trusts every page host of a company, and nobody asked for it.
- **Where the check runs.** First thing in the client lookup, before the cache and the fetch
  (chosen), so every path (authorize, token, revoke, the bearer check, the account page) gets it
  and no request leaves for an unlisted host. Rejected: checking in each HTTP handler (easy to
  miss one), or after the fetch (keeps the request-forgery surface).
- **The words a refused client gets.** fosite replaces the hint of a failed client lookup with
  its own sentence, so the lookup's error carries a marker and the handlers put the sentence
  back (`invalid_client`, 401). At `/authorize` there is no accepted redirect URI, so fosite
  shows the error in the browser and redirects nowhere.
- **Registration off.** RFC 7591 defines error codes only for bad metadata, none for "closed".
  Chosen: `403` with the RFC's JSON error shape and `access_denied` (RFC 6749's code for a
  refused request) plus the sentence. Rejected: `404` (reads as a broken relay), `400
  invalid_client_metadata` (blames the metadata). The endpoint is also left out of the
  metadata, which is what clients actually read.
- **`token_endpoint_auth_methods_supported` with a list.** Only `none` (chosen): without
  registration no client has a secret, so advertising the secret methods would be untrue.
  `none` is the signal Claude needs.
- **Clients stored from before.** Deleted with their codes and tokens at start and in the daily
  purge, in one transaction (chosen), and refused at lookup in between. Rejected: leaving the
  rows to expire (refresh tokens live 90 days).
- **Default inside the code.** The zero value means `claude.ai` (chosen), so a new caller that
  forgets the setting gets the strict behaviour; tests and local checks that register a
  throwaway client say `*` explicitly.

Sources: https://claude.com/docs/connectors/building/authentication,
https://claude.com/docs/connectors/building/lazy-authentication,
https://modelcontextprotocol.io/specification/draft/basic/security_best_practices (allowlists
of trusted domains for metadata documents), RFC 7591 §3.2.2, RFC 6749 §4.1.2.1.

## Encrypting the relay's own keys (FR-186 to FR-189, 2026-10-25)

`relay_keys` held the OAuth token HMAC key and the CSRF key as plain bytes, against Constitution
VI. Nothing else in the database is a usable secret: tokens are stored by signature, sessions,
email codes, pairing codes and client secrets as hashes, passkeys and device keys are public
keys. (Outside the database, built-in HTTPS keeps its certificate keys unencrypted in
`DATA_DIR/certs`; the hosted relay doesn't use it. Not changed here.)

Toni chose a key file, made automatically. OWASP's Cryptographic Storage Cheat Sheet: AES with
an authenticated mode, GCM first; keys stored apart from the data they protect; a protected file
rather than an environment variable. Choices made:

- **Cipher.** AES-256-GCM from Go's standard library (chosen), a random 12-byte nonce per
  value, the row's name as additional data so a value can't be swapped between rows. A handful
  of values are ever sealed under one key, far below GCM's limit for random nonces.
  XChaCha20-Poly1305 would also do; it adds a dependency for no gain here.
- **Stored form and its version.** A `format` column (chosen): 0 is the old plain value, 1 is
  nonce, ciphertext, tag. A version byte inside the value was rejected because an old plain
  key is 32 random bytes and can start with any byte, so it couldn't be told apart from a
  sealed one with certainty.
- **Key file format.** 32 raw random bytes (chosen), mode 0600, made with `O_EXCL` and synced.
  Text encodings invite trailing-newline mistakes; a passphrase with a KDF would need someone
  to type it at every start.
- **Where it is handled.** In `store.Open` (chosen), so no code path can read a key before the
  file is checked and old rows are converted; `Open` uses `relay.key` next to the database,
  which is also the default `KEY_FILE`.
- **Conversion.** One transaction: seal, write, read back, open, compare, roll back on any
  difference (the "moving stored data" gotcha in `.claude/rules/macos.md`). The key values
  don't change, so tokens stay valid. `secure_delete`, `VACUUM` and a truncated write-ahead
  log remove the old bytes from the file.
- **When the key file doesn't fit.** Refuse to start and say what to do (chosen). Making a new
  key and new signing keys by itself would silently sign everyone out and hide a lost or
  swapped file. The operator's explicit way out is `relay reset-keys --confirm`.
- **Permissions.** Any group or other permission bit is refused, as OpenSSH does for private
  keys. Symbolic links are followed (container secret mounts are links).
- **Hosted layout.** `/opt/latchkey/keys` root-only, `/opt/latchkey/keys/relay` owned by the
  container's user (uid 65532) and mounted at `/keys`. The container runs without root and
  without capabilities, so the folder has to belong to its user; the root-only folder above
  keeps every other user on the VM out. A named volume was rejected: it would sit next to the
  data volume and be copied with it.
- **Rollback across the conversion.** An earlier version reads the stored bytes as the key
  itself, so on a converted database it would quietly run with wrong keys. Chosen: the first
  deploy (key file absent on the VM) stops the relay, copies the database files to a root-only
  folder, and the rollback puts them back and deletes the new key file; the copy is deleted
  once the new version answers, because it holds the keys unencrypted. Rejected: keeping the
  copy for later (it defeats the encryption), or a conversion the old version could undo.
  The nightly disk copies (14 days) still hold the old plain keys until they age out, and hold
  database and key file together afterwards: a whole-disk copy is a copy of the whole relay.

Sources: https://cheatsheetseries.owasp.org/cheatsheets/Cryptographic_Storage_Cheat_Sheet.html,
https://pkg.go.dev/crypto/cipher#NewGCM, NIST SP 800-38D §8.3 (random nonces),
https://www.sqlite.org/pragma.html#pragma_secure_delete.
