# Run your own Latchkey relay

The relay is one container with one data volume. It needs an email server for sign-up and
recovery links, and an HTTPS address that Claude can reach.

## What you need

- A server that is reachable from the internet, or a tunnel to one (see "HTTPS" below).
- A domain name pointing at it, for example `relay.example.com`.
- An SMTP account for sending email (your email provider, or a service such as Postmark,
  Amazon SES, or Fastmail).
- Docker.

## Start it

```sh
docker run -d --name latchkey-relay --restart unless-stopped \
  --read-only --tmpfs /tmp:size=16m --cap-drop ALL --security-opt no-new-privileges \
  -p 443:8080 \
  -v latchkey-data:/data \
  -e PUBLIC_URL=https://relay.example.com \
  -e ACME_EMAIL=you@example.com \
  -e SMTP_HOST=smtp.example.com -e SMTP_PORT=587 \
  -e SMTP_USER=relay@example.com -e SMTP_PASSWORD='…' \
  -e SMTP_FROM='Latchkey <relay@example.com>' \
  -e ALLOWED_EMAILS=you@example.com \
  ghcr.io/tonimelisma/latchkey-relay:latest
```

Then open `https://relay.example.com`, create your account, and continue with "Connect" below.

## Settings

| Variable | Required | Meaning |
|---|---|---|
| `PUBLIC_URL` | yes | The relay's public address, `https://` with no path. Claude's connector URL is this plus `/mcp`. |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_FROM` | yes | Outgoing mail server. Port 465 uses TLS directly; other ports require STARTTLS, and the relay refuses to send to a server that doesn't offer it. Only a mail server on the same machine (`localhost`, for testing) may be reached without encryption. |
| `SMTP_USER`, `SMTP_PASSWORD` | no | Set both, or neither if the server needs no login. |
| `ALLOWED_EMAILS` | no | Comma-separated addresses allowed to sign up. Empty means anyone can sign up; set it to your own address on a personal relay. |
| `ACME_EMAIL` | no | Turns on built-in HTTPS with Let's Encrypt (see below). |
| `PORT` | no | Port inside the container, default 8080. |
| `DATA_DIR` | no | Already `/data` in the image. |

Everything the relay stores is in the `/data` volume: one SQLite file, plus cached certificates
when built-in HTTPS is on. Back up that volume to back up the relay.

## HTTPS

Claude only connects over HTTPS. Pick one:

- **Built-in (simplest on a bare server).** Set `ACME_EMAIL` and map public port 443 to the
  container's port, as in the example above. The relay gets and renews its own Let's Encrypt
  certificate and keeps it in `/data/certs`.
- **A reverse proxy you already run** (Caddy, Traefik, nginx). Leave `ACME_EMAIL` unset and proxy
  `https://relay.example.com` to the container's port 8080. WebSocket upgrades must pass through
  (Caddy and Traefik do this by default; nginx needs `proxy_http_version 1.1` and the `Upgrade`
  and `Connection` headers). With Caddy:

  ```
  relay.example.com {
      reverse_proxy localhost:8080
  }
  ```
- **A hosting platform** (Fly.io, Render, Google Cloud Run, Railway). The platform provides
  HTTPS; the relay reads the port from `PORT`. Give it a persistent volume at `/data`.
- **A home server without a public address.** Use a tunnel such as Cloudflare Tunnel to
  `localhost:8080`. The tunnel is for the relay only; your Mac still just dials out.

## Built-in protections

- **Abuse limits.** Sign-in, passkey, pairing, and account requests, client registration, the
  consent page, the token endpoint, and Mac connections are limited per client address; sign-in
  emails are limited per address and for the whole relay; MCP calls are limited per account. The
  limits sit far above normal use. A request over a limit gets `429 Too Many Requests`.
- **Client addresses behind a proxy.** When a request comes from a proxy on the same machine or a
  private network (as with Caddy, Traefik, nginx, a hosting platform's router, or a tunnel's local
  connector), the relay takes the client's address from the last `X-Forwarded-For` entry, the one
  the proxy added. Requests straight from the internet can't set it. Make sure your proxy adds
  that header (the ones above do by default).
- **Headers.** Every response forbids framing, sniffing, referrers, and caching; over HTTPS it
  also sends `Strict-Transport-Security`.
- **Container.** The `docker run` flags above make the filesystem read-only except `/data` and a
  small `/tmp`, and drop all Linux capabilities; the image runs as a non-root user.

## Connect

1. **Claude:** in Claude, open Settings → Connectors → Add custom connector, and enter
   `https://relay.example.com/mcp`. Sign in with your passkey when asked and click Allow.
   Adding it once on claude.ai makes it available in Claude on the web, Desktop, and the phone
   apps.
2. **Mac:** in the Latchkey menu bar app, choose Connect to a Relay…, enter
   `https://relay.example.com`, and confirm in the browser.

## Updating

```sh
docker pull ghcr.io/tonimelisma/latchkey-relay:latest
docker rm -f latchkey-relay
# run the same docker run command again
```

The database is migrated automatically on start.
