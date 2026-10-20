# Decisions

Approved by Toni. Each row points to where the decision is specified; the spec is authoritative.
Add a row when a decision is made; never delete one, mark it "superseded by" instead.

| Date | Decision | Where |
|---|---|---|
| 2026-10-19 | Product for others from day one; free and open source (MIT or Apache-2.0) | Constitution IX |
| 2026-10-19 | One Mac per user; Apple silicon only; current + previous macOS | spec FR-075 |
| 2026-10-19 | NAT traversal by the Mac app's own outbound WebSocket; no cloudflared, ngrok, Tailscale | plan D1, Constitution I |
| 2026-10-19 | Relay in Go, SQLite only, single server first, Docker, self-hostable | plan D10, Constitution V |
| 2026-10-19 | Relay speaks MCP itself: handshake, cached tool list, `laptop_status` offline | plan D2, FR-013 |
| 2026-10-19 | Fail fast: per-call deadlines, default 10 s, cap 60 s | plan D3, FR-011 |
| 2026-10-19 | Relay remembers online/last seen, battery, power, thermal, keep-awake; no request queueing | FR-020, FR-025 |
| 2026-10-19 | Relay audit log: metadata only, 30 days | FR-022, FR-024 |
| 2026-10-19 | Mac keeps full local trace with arguments and results, 90 days | FR-026 |
| 2026-10-19 | Encrypted in transit is enough; relay never stores tool results | FR-023, Constitution VI |
| 2026-10-19 | Claude auth: OAuth 2.1 with fosite plus our own CIMD and DCR client lookup | plan D4, FR-040 |
| 2026-10-19 | Owner login: passkeys only; recovery by single-use email link over SMTP | plan D5, FR-041, FR-042 |
| 2026-10-19 | Pairing via browser sign-in; Secure Enclave device key | plan D6, FR-050 |
| 2026-10-19 | Custom connector URL now; Anthropic connector directory later | spec US1 |
| 2026-10-19 | Native Swift menu bar app, notarized direct download, Sparkle; no App Store; not sandboxed | plan D9 |
| 2026-10-19 | Keep-awake always, lid closed on battery too, via `SMAppService` helper over XPC (no CLI, no sudoers) | plan D7, FR-030 |
| 2026-10-19 | Low battery: fixed 15%, report and allow sleep | FR-032 |
| 2026-10-19 | Too hot (serious/critical): report and allow sleep | FR-033 |
| 2026-10-19 | Keep-awake re-enables automatically when safe | FR-034 |
| 2026-10-19 | User chooses capabilities in the app; disabled = invisible; per-call approval left to Claude apps | FR-060, FR-061, Constitution III |
| 2026-10-19 | First tool `battery_status`; then files, Notes + iMessage, shell, browser/computer, one spec each | FR-063 |
| 2026-10-19 | Offline messages in the Mac's time zone | FR-037 |
| 2026-10-19 | Relay web access logs kept 30 days | data-model.md |
| 2026-10-19 | Terms and privacy policy deferred; launch blocker | spec open questions |
| 2026-10-19 | Name: Latchkey | README |
| 2026-10-20 | CLAUDE.md slim; status in docs/STATUS.md; decisions here; topic rules in .claude/rules | CLAUDE.md |
| 2026-10-20 | No slash-command skills; Toni says "next step" and Claude takes the top item in docs/STATUS.md | CLAUDE.md |
