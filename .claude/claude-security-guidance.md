# Security guidance for Latchkey

The full threat model is `docs/threat-model.md`; its "Accepted risks" are decisions, not findings.
In short: the relay forwards Claude's tool calls to the owner's Mac, and with Shell and Computer
control on, any forwarded call runs as the owner. Review every change for:

- `/mcp` and everything under `relay/internal/oauth/`: a request reaches only the Mac of the
  account its token belongs to; tokens checked for expiry, revocation, and audience; PKCE S256
  and registered redirect URIs required; codes single-use; refresh reuse after 60 s revokes the
  family.
- Account pages, pairing, passkeys: state-changing POSTs need the session cookie and the CSRF
  token; codes are hashed, expire in 15 minutes, allow 5 wrong attempts, and are rate-limited.
- The Client ID Metadata Document fetch reaches only public HTTPS addresses, with size and time
  limits (no loopback, private, link-local, or metadata addresses, including after redirects
  and DNS changes).
- The relay never waits on the Mac without a deadline; no unauthenticated input grows memory,
  goroutines, connections, or database rows without a bound.
- On the Mac, a capability turned off is absent from the tool list and refused if called anyway,
  whatever the relay sends.
- Strings from Claude are never spliced into AppleScript, JavaScript, SQL, or a shell command
  line except where the tool exists to run them (`shell_run`, the script action of
  `browser_act`); read-only tools change nothing.
- The root helper accepts only callers with the app's code-signing requirement and only sets
  sleep on or off.
- Never commit, log, or return in an error: the hosted relay's address, server details, the Apple
  team ID, API keys, tokens, sign-in codes.

Not findings here (decided by the owner): prompt injection through tool results, the absence of
per-call approvals on the Mac, tools acting with the owner's full rights when turned on, and a
compromised relay being able to call capabilities that are on.
