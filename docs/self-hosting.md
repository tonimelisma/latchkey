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
| `TRUSTED_PROXIES` | no | Comma-separated IP addresses and CIDR ranges (for example `172.18.0.0/16`) of reverse proxies whose `X-Forwarded-For` header the relay believes. Set it whenever a proxy sits in front of the relay in Docker: to the Docker bridge gateway for a proxy on the server itself, or to the shared network's range for a proxy in a container (see "HTTPS"). Only connections from the relay's own loopback address are believed without it, and a container never sees the server's proxy as loopback. Empty with a proxy in front means all visitors share one abuse limit. |
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
  and `Connection` headers). Two things matter for safety: only the proxy may reach the relay's
  port, and the relay must know the proxy's address (`TRUSTED_PROXIES`), or it can't tell
  visitors apart.

  *Proxy installed on the server itself.* Publish the port on the loopback address only, and
  trust the address the proxy's connections arrive from inside the container, which is Docker's
  bridge gateway:

  ```sh
  docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}'   # usually 172.17.0.1
  ```

  In the `docker run` command above, drop `ACME_EMAIL` and replace `-p 443:8080` with:

  ```sh
    -p 127.0.0.1:8080:8080 \
    -e TRUSTED_PROXIES=172.17.0.1 \
  ```

  ```
  relay.example.com {
      reverse_proxy 127.0.0.1:8080
  }
  ```

  Never publish the port as `-p 8080:8080` behind a proxy: that opens it on every network
  interface, so visitors can skip the proxy, and on some Docker setups they then arrive from
  that same gateway address and can fake the address the relay limits them by.

  *Proxy in its own container.* Put both on one Docker network and publish no relay port at all
  (no `-p`). Trust that network's address range:

  ```sh
  docker network create proxy
  docker network inspect proxy --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'   # e.g. 172.18.0.0/16
  ```

  Run the relay with `--network proxy -e TRUSTED_PROXIES=172.18.0.0/16` (your range), and point
  the proxy at the container by name: `reverse_proxy latchkey-relay:8080`. Every container on
  that network is believed, so keep it to the proxy and the sites behind it.

  *If you leave `TRUSTED_PROXIES` empty* in either setup, the relay still works, but it sees
  every visitor as the proxy: all of them share one abuse limit, so one person's failed sign-ins
  or a flood of requests can lock everyone out for a while.
- **A hosting platform** (Fly.io, Render, Google Cloud Run, Railway). The platform provides
  HTTPS; the relay reads the port from `PORT`. Give it a persistent volume at `/data`.
- **A home server without a public address.** Use a tunnel such as Cloudflare Tunnel to
  `127.0.0.1:8080`, with the port published and `TRUSTED_PROXIES` set exactly as for a proxy on
  the server itself (above). The tunnel is for the relay only; your Mac still just dials out.

## Built-in protections

- **Abuse limits.** Sign-in, passkey, pairing, and account requests, client registration, the
  consent page, the token endpoint, and Mac connections are limited per client address; sign-in
  emails are limited per address and for the whole relay; MCP calls are limited per account. The
  limits sit far above normal use. A request over a limit gets `429 Too Many Requests`.
- **Client addresses behind a proxy.** When a request arrives from the relay's own loopback
  address or from an address listed in `TRUSTED_PROXIES`, the relay takes the client's address
  from the last `X-Forwarded-For` entry, the one the proxy added. From any other address the
  header is ignored, even from a private network, so nobody else can fake it. A relay in a
  container sees a proxy on the server as Docker's bridge gateway, not as loopback, so list the
  proxy's address as the relay sees it (the gateway, the proxy's container network, a hosting
  platform's router, a tunnel connector); otherwise every client shares the proxy's address for
  the abuse limits. Make sure your proxy adds that header (the ones above do by default).
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
