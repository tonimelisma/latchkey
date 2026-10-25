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
| `ALLOWED_CLIENT_HOSTS` | no | Which apps may ask for access to an account, as a comma-separated list of host names. Default `claude.ai`: only Claude's apps (web, Desktop, phone, Cowork, Claude Code). See "Which apps can connect". |
| `KEY_FILE` | no | Path of the key file that encrypts the relay's own signing keys. Default `/data/relay.key`. See "The key file". |
| `OPERATOR_NAME`, `OPERATOR_CONTACT` | no | Who runs this relay, and an email address for questions, privacy requests, and security and abuse reports. Set both, or neither. With both, the relay publishes terms of service at `/terms` and a privacy policy at `/privacy`, links them from every page, and tells Claude's apps where they are. Leave them out on a relay only you use. |
| `OPERATOR_LAW` | no | The law your terms are under, for example `California, USA`. The terms say so only when this is set. |
| `OPERATOR_PROVIDERS` | no | The companies that handle your relay's data for you, in your own words, for example `Example Cloud (hosting) and Example Mail (email delivery)`. Shown in the privacy policy; without it the policy says "the operator's hosting and email providers". |
| `BACKUP_DAYS` | no | How many days you keep backups of the server. The privacy policy mentions backups only when this is set. |
| `PORT` | no | Port inside the container, default 8080. |
| `DATA_DIR` | no | Already `/data` in the image. |

Everything the relay stores is in the `/data` volume: one SQLite file, the key file (unless you
moved it, below), plus cached certificates when built-in HTTPS is on. Back up that volume to
back up the relay.

## Which apps can connect

Out of the box only Claude's own apps can ask for access. They identify themselves with an
address on `claude.ai`, and the relay refuses any app that identifies itself from another host,
before contacting that host. Apps also can't register themselves with the relay. A refused app
is told "This relay only accepts Claude's apps."

To let another app in, list its host as well, for example
`ALLOWED_CLIENT_HOSTS=claude.ai,apps.example.com`. Names are exact: no `https://`, no port, no
wildcards, and a subdomain is a different name. The app must publish a client ID metadata
document on that host, and every address it sends your browser back to must be on a listed host
or on your own computer.

`ALLOWED_CLIENT_HOSTS=*` accepts any app and turns self-registration back on. Whatever the
setting, nobody gets access without you signing in and pressing Allow; the list decides who may
ask.

When you narrow the list, apps that no longer fit lose their access at the next start. A value
the relay can't read as a list of host names stops it from starting, with the reason.

## The key file

The relay signs Claude's access tokens with keys of its own. They are stored in the database
encrypted, and the key that opens them is in a separate file, the key file. Someone who gets a
copy of the database without the key file can't forge access.

- The relay makes the file on its first start (32 random bytes, readable only by the relay's
  user) and says so in its log. It never prints the key. Upgrading from a version without a key
  file needs nothing from you: the first start makes the file and encrypts the stored keys, and
  everyone stays signed in.
- By default it is `/data/relay.key`, next to the database. That protects a copy of the database
  file, but not a copy of the whole volume. For more, keep it somewhere else: mount a folder
  that only the relay's user can read (in the container that is user 65532) and point `KEY_FILE`
  at a file in it. The folder must exist; the relay creates the file.

  ```sh
  sudo install -d -m 700 -o 65532 -g 65532 /srv/latchkey-key
  # add to the docker run command:
    -v /srv/latchkey-key:/keys -e KEY_FILE=/keys/relay.key \
  ```

- **Back it up apart from the database.** A backup that holds both is as good as the relay
  itself to whoever reads it.
- The file must stay private: if other users can read it, the relay refuses to start and tells
  you to `chmod 600` it.
- **If the key file is lost or doesn't match**, the relay refuses to start and says so. Put the
  file back from your backup. If you don't have it, delete the stored keys, with the relay
  stopped:

  ```sh
  docker run --rm -v latchkey-data:/data ghcr.io/tonimelisma/latchkey-relay:latest reset-keys --confirm
  ```

  Everyone is signed out and Claude is disconnected: each person signs in again and adds the
  connector's access again. Accounts, passkeys, and paired Macs are kept. The relay never does
  this by itself. The next start makes new keys, and a new key file if there is none.
- Going back to a relay version from before the key file doesn't work on the same database (it
  can't read the encrypted keys). Keep a copy of the database from before the upgrade if you
  want that option, or run `reset-keys` after going back.

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

## Terms and privacy policy

If other people may sign up on your relay, set `OPERATOR_NAME` and `OPERATOR_CONTACT`. The relay
then shows its own terms of service and privacy policy, filled in with your details; the privacy
policy lists exactly what the relay stores. Read both before you rely on them: they are
plain-language texts that come with the software, not legal advice, and what your country
requires of you may differ. The relay refuses to start if only one of the two is set, or if the
contact isn't an email address.

## For operators: dealing with abuse

The relay's image has no shell, so these are commands of the relay program itself. Run them on
the server while the relay is running:

```sh
docker exec latchkey-relay /relay account list
```

| Command | What it does |
|---|---|
| `account list` | Every account: address, when it was created, last sign-in, whether it is suspended, whether a Mac is connected, and how many Claude apps have access. No secrets. |
| `account suspend <email> [reason]` | Signs the account out everywhere, removes Claude's access, disconnects its Mac, and refuses its sign-ins and its Mac until you lift it. Nothing is deleted, and the Mac stays paired. |
| `account unsuspend <email>` | Lifts a suspension. The owner can sign in again and has to approve Claude again. |
| `account delete <email>` | Deletes the account and everything stored about it, like the Delete account button. |
| `block <email> [reason]` | The address can no longer sign up or sign in. If it has an account, the account is suspended. |
| `unblock <email>` | Removes the block. An account that was suspended with it stays suspended until you run `account unsuspend`. |
| `block list` | The blocked addresses, with when and why. |

- Each command prints one line saying what it did. If it couldn't do it (no such account, not
  an email address), it says why and exits with an error.
- Addresses are matched the way sign-up stores them, so capital letters don't matter.
- A suspended or blocked person who tries to sign in is told so, with your contact address if
  you set `OPERATOR_CONTACT`.
- The running relay follows a command right away for everything new (sign-ins, Claude's
  requests, a Mac connecting). A Mac that is connected at that moment, and Claude's open
  sessions, are closed within about two seconds.
- Every command that changed something is recorded in the database: who ran it, what, when, and
  the reason you gave. The record is kept for a year. "Who" is the system user that ran the
  command (`nonroot` in the container); to record a person's name, pass it along:
  `docker exec -e LATCHKEY_OPERATOR=alex latchkey-relay /relay account suspend …`.
- A mistyped command prints the list of commands and does nothing. `relay` with no command
  starts the server, as before.

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

The database is migrated automatically on start. The first start of a version with the key
file encrypts the relay's stored keys (see "The key file").
