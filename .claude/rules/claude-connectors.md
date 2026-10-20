---
paths:
  - "relay/**"
  - "specs/**/contracts/mcp-surface.md"
---

# How Claude's connector client behaves (verified 2026-10; sources in specs/001-core/research.md)

- Claude calls the relay from Anthropic's cloud (egress `160.79.104.0/21`), never from the user's
  device. The `/authorize` page is opened in the user's own browser, from anywhere.
- Discovery: unauthenticated `/mcp` must return `401` with
  `WWW-Authenticate: Bearer resource_metadata="..."`. Claude ignores that header on any other status.
- Protected resource metadata `resource` must equal the connector URL exactly, path included.
- Claude uses only the first entry in `authorization_servers`.
- Claude uses CIMD only if auth server metadata has `client_id_metadata_document_supported: true`
  AND `none` in `token_endpoint_auth_methods_supported`; otherwise it falls back to DCR.
- PKCE S256 on every request; advertise `code_challenge_methods_supported: ["S256"]`.
- Redirect URIs: `https://claude.ai/api/mcp/auth_callback` (web, Desktop, mobile, Cowork);
  Claude Code uses loopback `http://localhost:<port>/callback` and `http://127.0.0.1:<port>/callback`
  with a varying port, so match ignoring the port.
- `offline_access` in `scopes_supported` makes Claude request a refresh token.
- Time limits: 10 s for discovery, registration, token endpoints; 30 s for refresh.
- `/token` must accept `application/x-www-form-urlencoded`; `/register` uses JSON.
- Expired or invalid refresh token: return `invalid_grant`. Rotate refresh tokens and return the
  new one in the same response.
- No `client_credentials` grant. Static header auth is a limited org beta: not an option.
- Cross-host redirects drop the `Authorization` header: never redirect `/mcp`.
- Claude's hosted runtime still sends `initialize` (2025-11-25); also support stateless 2026-07-28.
