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
  outcome, duration as one JSON blob). The time stays plain so the 90-day purge is one query
  (the purge is gone since 2026-10-26; the time now serves sorting and the date filter).
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
- A key that can't be read (2026-10-25): leave it and run without the log for the launch
  (chosen: nothing is lost, and the next launch may read it), versus making a new key beside it
  under another name (rejected: two keys and a log readable in halves, for a fault that should
  not last), versus replacing it (what 0.8.4–0.8.7 did: the log under the old key is lost for
  good). Calls made during such a launch are not recorded.
- Entries whose key is gone (2026-10-25): left out of the menu and counted in one line of the
  Activity window (chosen: the menu is for what Claude just did, and an entry nobody can read is
  not something to act on), versus listing each as "can’t be read" (rejected: up to hundreds of
  identical rows pushing real entries out of sight). Returning "no entry" instead of a made-up
  failed "unknown" entry is what keeps them from ever counting as failures.
- Testing "exists but unreadable" against the real Keychain was tried and dropped: an item whose
  access list trusts no program makes macOS ask the Owner on screen and blocks the test run. The
  meaning of the Keychain's answers is a pure function with its own test instead.

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

## Apps with access: what a grant is and how it is named (FR-190 to FR-192, 2026-10-25)

- **Where a grant's label lives.** A new `oauth_grants` row written at approval (chosen): the
  list shows exactly what the consent page showed, even if the client's document changes later,
  and there is a place for the public ID and the last-used time. Versus deriving everything from
  `oauth_requests` (no schema change, but the redirect host is lost after the first refresh,
  the approval time would be a guess, and last-used needs a column anyway), versus columns on
  every `oauth_requests` row (repeated on each rotation).
- **The public ID.** 16 random bytes generated at approval (chosen); versus a hash of the
  request ID (stable without storage, but one leaked request ID would name the grant, and a
  keyed hash adds a key to manage); versus the request ID itself (it is fosite's internal handle
  and appears in logs). Never a token signature.
- **What "live" means.** An unrevoked, unexpired access or refresh token (chosen, and what the
  account page meant already); an approval whose code was never redeemed is not access.
  Therefore "a new approval" reaches the Mac when the code is redeemed, seconds after Allow.
- **Finding out that a client revoked, or that a token was reused.** fosite calls the storage
  (`RevokeRefreshToken`, `RevokeAccessToken`) for both; the adapter then checks whether the
  grant is still live and reports the change if not (chosen). Versus wrapping the `/revoke`
  handler (misses reuse detection, which happens inside the token endpoint).
- **Closing one grant's MCP sessions.** The SDK binds a session to a user, not a token. Chosen:
  remember, per session ID, the grant that opened it (read from the response header of the
  request that created the session) and close those. Versus closing all of the Owner's sessions
  (disturbs the other apps, which the requirement forbids), versus one MCP server per grant
  (multiplies the tool-list bookkeeping).
- **Last used at most once a minute.** An in-memory map of grant → last write, checked before
  the write (chosen: no database write, or even statement, on most requests); the map is
  emptied of entries older than a minute whenever it passes 10,000. Versus a conditional
  `UPDATE` per request (a statement per request).
- **Old grants.** Migration 10 gives every existing grant a row with an empty label; the list
  reads the name and hosts from the client instead (its first redirect host stands in for
  where the approval went).
- **A client with no name.** Listed as "An unnamed app" (the relay's existing words for it),
  so the Mac never shows an empty row.

## Terms and privacy pages (FR-193, FR-194, 2026-10-25)

- Anthropic's Software Directory Policy asks for a privacy policy link and contact information
  (§3A, §3B); RFC 8414 §2 defines `op_policy_uri` and `op_tos_uri` for exactly this.
- **Texts in templates, operator details from settings** (chosen), versus a file the operator
  mounts (every self-hoster would have to write one; most would have none), versus fixed text
  naming the hosted relay's operator (a self-hosted relay would publish someone else's name).
- **Keeping the policy true.** A test with one required phrase per stored table, checked
  against `data-model.md` and against the migrated database (chosen); versus generating the
  policy from the data model (unreadable prose).
- **Where the agreement sentence goes.** The email step of the one sign-in page (chosen: it is
  where an account is created, FR-043a); it also shows to people signing in, which is harmless.
- The governing-law sentence, the list of providers, and the backup sentence appear only when
  their settings are given, so a relay never claims something its operator didn't state.

## Operator commands and suspension (FR-195 to FR-199, 2026-10-25)

- **How the running relay learns of a command.** Options: (a) the relay polls the operator log
  for new entries every 2 s (chosen: one indexed query, works with any way of running the
  command, and the log is needed anyway); (b) the command calls the relay over loopback HTTP
  (instant, but adds an unauthenticated control endpoint inside the container and fails when
  the port or TLS mode differs); (c) SQLite's `data_version` pragma (changes on every commit of
  any other connection, the relay's own pool included). Everything checked per request reads
  the database and needs no notice at all; the poll only reaches open connections.
- **Close code for a suspended Mac.** 4001 (chosen): the app shows "Sign in again" and keeps
  its key. 4002 would make it delete the key, turning a suspension into an unpairing; a new code
  would be a protocol violation to the installed app.
- **Who ran a command.** The operating-system user of the process (`nonroot` in the image),
  or `LATCHKEY_OPERATOR` when set, so several people sharing a server can say who they are.
- **Last sign-in in `account list`.** The newest of the account's passkey uses and browser
  sessions, both already stored; no new column.
- **Recovery for a suspended account** says so plainly, although recovery otherwise answers the
  same for known and unknown addresses (FR-042b): only an account the operator suspended is
  revealed, and the ordinary sign-in step already tells a known address from an unknown one.
- **How long the operator log is kept.** One year (chosen: long enough to answer "why was my
  account suspended" and to see a pattern of abuse, short enough not to keep addresses of
  deleted accounts forever). [Toni to confirm.]

## The relay's event record and the audit's call ids (FR-630 to FR-636, 2026-10-27)

Toni decided what is recorded, that nothing is deleted by age, and that the record goes with the
account. What was left to Claude:

- Where events live: one `events` table for every kind, with a kind, an account, a Mac, and a
  detail of fixed words (chosen: one query lists an account's history in order, and a new kind
  needs no migration) versus a table per kind (typed columns, but a join of a dozen tables to
  read one history) versus only log lines (gone when the container's output is rotated or the
  container replaced: not a record).
- Stranger requests, which must not grow the database without bound: counted per hour, kind,
  account, and detail in one row with `count`, first and last time (chosen) versus a row per
  request with a cap or a sample (a cap drops exactly the flood one wants to see, and a sample
  loses the count) versus not recording them (FR-631 asks for every refusal with its reason).
  Details never hold what the client sent (the route pattern, not the path; fixed reasons, not
  error text), so the rows without an account are bounded by the number of kinds and reasons
  per hour. The same counting is used for an account's refusals and for the sign-in steps anyone
  can cause for a known address (a wrong code, a recovery request): a stranger who knows an
  address then adds at most one row per reason an hour to that account. Successful sign-ins,
  connections, approvals, and pairings are rows of their own. Only the first counted event of
  an hour is logged, so the output is bounded the same way.
- Unfinished sign-ups: their steps are counted without an account (chosen) rather than with the
  unverified account, whose rows the daily purge of unfinished sign-ups would delete with it
  after a day; once the address is confirmed, the sign-up is an event of the account.
- Call ids: Crockford base32, upper case, of 16 random bytes (chosen; 26 characters as the
  contract says, no padding, no letters that read as digits) versus RFC 4648 base32 (`=`-free
  but mixes `0`/`O` and `1`/`I` when a person compares ids) versus a ULID (sortable, but the
  time in the id adds nothing: the audit has `at`).
- Paging the audit: by `at` with `next_since`, never ending a page inside a millisecond whose
  rows go on (chosen: no row is skipped and none is sent twice) versus `last at + 1` always (skips
  a row that shares the last one's millisecond) versus `last at` always (repeats rows, and loops
  when one millisecond holds a whole page). Only when one millisecond holds more than a page
  (1,000 calls of one Mac in one millisecond, which the per-account limits make impossible) does
  the page end there and skip the rest of it.
- `since` or `limit` that is a number out of range gets an empty page (the contract); a value of
  the wrong JSON type, or a missing or longer than 128-byte `id`, is a malformed message (4005),
  as for every other message. `audit_request` from an app that didn't announce `audit` is a
  protocol violation (4005), so the relay never sends `audit` to an app that can't read it.
- The MCP SDK's lines: its servers get the relay's logger filtered to warnings and errors
  (chosen: its warnings stay) versus a discard logger (would hide its errors too).

## Menu bar design (FR-600 to FR-605, spec 002 FR-131, 2026-10-26)

Apple's Human Interface Guidelines (developer.apple.com/design/human-interface-guidelines):
- The menu bar: a menu bar extra shows a menu, not a popover; its icon is a template image
  (black and clear only), 24 pt bar; people may hide it, and the system hides extras when the
  bar is crowded, so nothing may depend on it being visible (the setup window and the Settings
  window offer everything).
- SF Symbols: use a symbol's slash variant to show that something is unavailable (`key.slash`
  exists on the supported releases); don't bake badges into custom symbols.
- Color: don't rely on color alone; use shapes or labels.
- Menus: be mindful of length; submenus sparingly, one level, about five items; "…" when more
  input is needed; title-style capitalization; a changing label ("Pause…"/"Resume…") or a
  checkmark for a state.
- Settings: infrequently changed settings go in a Settings window opened with Command-comma; a
  non-customizable toolbar of panes; the title names the pane; reopen to the last pane.
- Alerts: confirm an uncommon destructive action that can't be undone, with a specific verb and
  Cancel.

Options weighed for Pause reaching Claude:
1. The Mac answers every call with an error (chosen): no relay or protocol change, the answer is
   immediate and says exactly why, and the tool list stays stable like an offline Mac's.
2. The Mac disconnects: the relay answers "offline", which is wrong ("paused" is not "offline")
   and Keep Mac Awake would be pointless.
3. The Mac sends an empty tool list: Claude can't tell the Owner why, and its apps cache lists.

## Tamper-evident activity log, kept for good (FR-610 to FR-615, 2026-10-26)

Toni decided: keep every entry; keep it on Disconnect; a keyed chain; a newest-entry record in
the Keychain; stay encrypted (a plain-text log was rejected: shell commands Claude runs could
read it); page, search, filter, export. What was left to Claude:

- Chain fields: a sequence number, a key ID, and an HMAC per row, all with defaults so
  SwiftData migrates the existing store in place (chosen) versus a versioned schema with a
  custom migration stage (more code, same result for added fields) versus a second table of
  checksums (two writes per entry that can disagree).
- What the HMAC covers: previous mac, seq, ID, stored time, key ID (chosen; only clear fields,
  so the check reads no sealed data: 100,000 entries in about 4 s in a Debug build) versus also
  the SHA-256 of the sealed box (catches changed content during the check, but the check would
  read every byte of the log, images included, each time the window opens). Changed content is
  caught anyway: the sealed box authenticates seq and ID as AES-GCM additional data, so a box
  that was changed or moved from another row doesn't open, and a box under the current key that
  doesn't open is reported as changed when it is loaded.
- Keys: chain key and key ID derived from the log key with HKDF-SHA256 (chosen; nothing new to
  store) versus a second Keychain key (one more item that can be lost). Anyone with the log key
  can forge the chain; the check is against other programs, which can't read the key without a
  macOS prompt.
- Counting unreadable entries (FR-203): a query on the key ID (chosen) versus decrypting every
  entry when the window opens (what 0.8.14 did; seconds at 100,000 entries). Old entries get
  their key ID in one pass at the upgrade; one that doesn't open gets "-" (a key restored from a
  backup later would still be shown, only counted wrongly).
- Where a check break points: the first entry that doesn't follow from the one before it (that
  entry was changed, or entries before it were removed or moved); every break is listed, by
  resyncing on the stored mac.
- The record's write order: entry saved first, record after (chosen). A stop between the two
  leaves the record one behind, which is never an alarm; the other order would leave a record
  naming an entry that isn't there. A power cut that loses SQLite's last write can still make
  the record ahead of the log; the warning says so ("or lost when the Mac shut down
  unexpectedly") rather than claim tampering.
- A record that can't be read or isn't understood: left alone and not written for the launch,
  one line in the window, no alarm (chosen; "couldn't read it" is not "isn't there", and a
  warning it can't back would teach the Owner to ignore it) versus replacing it (destroys the
  evidence it might hold). A missing record while checked entries exist: said in one line,
  started again with the next entry (the Keychain may let other programs delete items even when
  they can't read them).
- Continuing after a cut-off end: from the record (chosen), so the gap stays in the chain as a
  break at the next entry, versus from the last row (the next record update would erase the
  evidence).
- Search: decrypt and match in the app, a batch of 1,000 at a time on every core (chosen) versus
  a search index (tokens or hashes of words on disk would let other programs learn what is in
  the log). Matching ignores case and accents; ASCII text goes through `strcasestr`, other text
  through Foundation (`range(of:options:)` alone made a whole-log search take 17 s).
- Export order: oldest first, like a log file, streamed page by page so a large log isn't held
  in memory. Arguments and results that are JSON are written as JSON; anything else as a
  string.

Measured (test `ActivityLogScaleTests`, Debug build, 100,000 entries of about 1 KB, 2026-10-26):
recording in batches of 1,000 10.8 s; opening the log 0.06 s; first page of 200 0.03 s; next page
0.02 s; the menu's 10 newest 0.03 s; tamper check of the whole log 4.1 s; text search with one match
in the whole log 3.1 s; tool filter, first page 0.03 s; last 30 days, first page 0.03 s; export of
the whole log 8.9 s; the log on disk 163 MB. A Release build is faster; entries with images take
longer to search and export, in proportion to their size.


## The Mac's audit trail: its own events, call ids, and the comparison (FR-632 to FR-634, FR-636, FR-637, 2026-10-27)

Toni decided the requirements (the Mac's events in the activity log, the relay's call id in
each entry, a comparison after each connection and on request, the installer failing on a gap).
Why: macOS's unified log discarded the app's diagnostic lines within hours (the `log show`
for the day of the audit came back empty), so it can't be the record. What was left to Claude:

- Where kind, call id, and device live: beside the sealed content, in the clear, with defaults
  (`kind` "action", `callID` "", `device` ""), so SwiftData upgrades the existing store in place
  as it did for the chain's fields (chosen; tested from the 0.8.15–0.8.23 schema with a real
  chain and record) versus inside the sealed JSON only (the comparison would decrypt every entry,
  images included, after every connection) versus a table of its own (two writes that can
  disagree). None of them is content: the kind says an entry is the app's own, the call id is a
  random id the relay has anyway, the device ID names the pairing. The Claude app's name
  (FR-637) is content-like (which app did what), so it is sealed with the entry instead
  (`client`, optional in the JSON, so older boxes open unchanged).
- Covering them by the chain: the checksum appends the three fields (each after a zero byte)
  only when one is not its default (chosen). An action without them is checksummed exactly as
  before, so the upgraded log's chain holds without rewriting a row, and changing any of them in
  the file breaks the chain at that entry. Versus always appending (every old checksum would
  need recomputing: a rewrite of Toni's log) or a version byte per row (one more field).
- Why a device column: the relay keeps an audit per device, so after pairing again the earlier
  pairing's calls are in another device's audit; without the device they would be reported
  missing on the relay after every re-pairing. They are left out and counted instead.
- The comparison's rules (`AuditComparison`): relay rows with an id and an outcome other than
  `offline` must be in the Mac's log; the Mac's actions with a `call_` id of this device must be
  in the relay's rows (an offline row with that id counts as present). Left out and counted:
  rows and entries without an id or with an older per-connection id (`c_1`), the Mac's calls of
  an earlier pairing, and anything on one side only from the last 120 s (the relay caps
  deadlines at 60 s, and a call the relay gave up on can still finish and be recorded on the
  Mac). The Mac's missing calls are named with their tool, decrypted only for those entries.
- Paging the relay's answer (security review, 2026-10-27): a page larger than asked, an entry
  before the page's `since`, a `next_since` not after both `since` and the page's newest entry,
  or more than a million entries in all is a malformed answer, and the check is reported "not
  possible" rather than looping or collecting without end. Each page has a 15 s deadline
  (Constitution II).
- A relay that doesn't know `audit_request`: the contract says it "answers nothing", but the
  relays deployed until now close the connection with 4005 on an unknown type. The app
  therefore remembers, for the life of the connection object, that a 4005 arrived while an audit
  page was asked for, never asks that relay again in this launch, and records "Audit check not
  possible: the relay doesn't answer audit requests" after each connection. Cost against an old
  relay: one extra reconnect per launch. Alternatives: a relay feature list in `welcome` (a
  protocol change for Toni and the relay side) or asking only after a `call_` id was seen (no
  check on a Mac that gets no calls). Toni decided (2026-10-27): no backwards compatibility, so
  the fallback was removed; the relay is deployed before an app that checks, and the installer
  fails on any "not possible" line.
- Events: one `EventLog` the whole app writes to, from any thread; each event goes to macOS's
  log (FR-620) and into the activity log. Before the log is open they wait in memory and are
  written in order; a failed save keeps them for the next (at most 10,000 held, and the number
  dropped beyond that is itself recorded). Polled states pass through `Changes` (keep-awake
  line, approvals line, the helper's problems), so the log holds changes, not repeats. Lines
  that carry the relay's address are kept out of macOS's public log (`systemLog: false`) and
  written there with their existing private formatting.
- What the installer reads: the `audit` category line starting "Audit check", within two
  minutes of the start (pages of up to 15 s, and a reconnect against a relay that closes on the
  request). Anything but "Audit check: all …" fails, an unpaired Mac excepted.
- The helper's "Sleep disabled" line: written when the value or the request changes, not on the
  app's once-a-minute re-apply.

The Activity window that took about 10 s to appear (2026-10-27, Toni's log: 321 entries, 19 MB
of screenshots): measured with a log of the same shape (`ActivityImageScaleTests`, 320 entries,
80 of them 180 KB JPEGs): opening the log 0.01 s, first page 0.02 s, rows 0.00 s, menu 0.01 s,
tamper check 0.03 s, comparison's calls 0.01 s, export 0.13 s with every image whole. A table of
200 such entries lays out in 0.11 s, the old details pane's full base64 text in 0.08 s. The
delay was not reproduced, so the window now holds small rows only (`ActivityRow`), shows an
image in the details pane as one line ("image/jpeg image, 180 KB, not shown") and cuts other
text at 10,000 characters, clips menu text from its first characters only, and logs "Show All
Activity chosen", "Activity window shown", and the first page's time in the `activity` category,
so the next slow open shows where the time went.
