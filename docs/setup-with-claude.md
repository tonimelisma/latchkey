# Set up a Latchkey relay: instructions for Claude Code

Draft for Toni's review (2026-10-31, spec 009). Not yet tested end to end.

You are Claude Code, helping someone set up their own Latchkey relay so Claude can use their
Mac from anywhere. Assume they have never used a terminal. Follow these steps in order.

## How to talk

- Plain, short sentences. No jargon; when a word is unavoidable, explain it in a few words
  ("a server: a computer in a data center that's always on").
- You run every command yourself. Never ask the person to type one.
- Ask them only for what only they can do: create an account, confirm a card or phone number,
  click Allow in a browser sign-in, make a passkey, add the connector in Claude.
- Before anything that can cost money, say what it costs. Never hide a cost.
- After each step, check it worked before moving on. When something fails, say what happened in
  plain words and what you'll do instead.
- Keep a short checklist in your replies so they always know where they are.

## Step 1: Explain the plan

Say:

> I'll set up your own Latchkey relay: a small always-on server that passes messages between
> Claude and your Mac. It takes about 20 minutes. You'll create an account with a hosting
> company and click Allow a few times; I'll do everything else.
>
> [The cost sentence from "Google Cloud" below.]
>
> Ready?

## Step 2: Hosting account

Follow "Google Cloud" below to get the person an account and sign Claude Code in. Say what
they'll see before they see it ("a page will ask for your card; Google checks it and charges
nothing while the relay stays within the free limits").

## Step 3: Create the relay

1. Make a setup code: 12 random letters and digits in groups of four (for example
   `K7PQ-M2XD-9RTA`). Keep it; the person needs it in step 4.
2. Create the server as "Google Cloud" says, with these settings:
   - image `ghcr.io/tonimelisma/latchkey-relay:latest`, kept up to date automatically
   - a persistent volume at `/data`
   - `PUBLIC_URL` = `https://` plus the relay's host name
   - `SETUP_CODE` = the code from 1
   - `ACME_EMAIL` = the person's email (Let's Encrypt's notices), port 443 open
3. Wait until `https://<host name>/` answers (up to 5 minutes for the certificate). Check with
   `curl -fsS https://<host name>/healthz`.

Say:

> Your relay is running at https://<host name>. Nothing on it is yours yet; next you'll claim it.

## Step 4: Claim it

Open `https://<host name>/` in their browser (`open https://<host name>/`). Say:

> A page opened. Click "Create account", enter your email address and this setup code:
> **<code>**. Then your Mac asks to save a passkey; click Continue. That's your key to the relay,
> kept in your iCloud Keychain.

Wait until they say it worked. If the page says the code is wrong, read it to them again.

## Step 5: Connect the Mac

Say:

> Now open Latchkey from the menu bar (the key icon) and choose Set Up. In the first step, enter
> https://<host name> and click Connect. Your browser opens; sign in with your passkey and click
> Allow. Then Latchkey asks macOS for its permissions one by one; click Allow in each.

## Step 6: Connect Claude

Say:

> Last step. On claude.ai, open Settings, then Connectors, then "Add custom connector". Name it
> Latchkey and paste https://<host name>/mcp. Click Connect, sign in with your passkey, and click
> Allow. It then works in Claude on the web, in Claude Desktop, and on your phone.

## Step 7: Check and finish

Ask them to ask Claude, in a new chat: "What's my Mac's battery level?" When it answers, say:

> Done. Your relay updates itself when a new version comes out. It runs on Google's free server;
> if anything ever costs more than $1, Google emails you. If you ever move it to another address, you'll make a new passkey and add the
> connector again; everything else stays.

Tell them where things are: the relay's address, the hosting company's page, and that the setup
code is no longer needed (sign-up is now closed).

## If they lose their passkey (later)

When someone comes back saying they can't sign in to their relay any more: sign in to Google
(`gcloud auth login`), then make a code on the server:
`gcloud compute ssh latchkey-relay --zone <zone> --command "sudo podman exec latchkey-relay /relay account recovery-code <their email>"`.
Then open the relay's page and say:

> Click "Lost your passkey?", enter your email address and this code: **<code>**. Then save the
> new passkey. Your Mac stays connected; nothing else changes. The code works once, for an hour.

## Google Cloud (the default host)

- Cost: "Google's free server costs nothing as long as it stays small, and a relay does. Google
  asks for a card to check you're a real person. I'll set an alert that emails you if anything
  ever costs more than $1." The free limits: one e2-micro server in Oregon, Iowa, or South
  Carolina, a 30 GB standard disk, and 1 GB of data out of North America a month (screenshots
  Claude takes count toward it; beyond it, a few cents per GB).
- Account: open https://console.cloud.google.com/freetrial. They sign in with a Google account,
  accept the terms, and enter a card. If they have a Google Cloud account already, use it.
  [To verify on a fresh account: whether the free trial's billing account must be upgraded to a
  full account for the free server to keep running after the trial's 90 days; if so, ask them to
  click "Activate full account" now and say it still costs nothing within the free limits.]
- Install Google's command-line tool, with no administrator password: download
  `https://dl.google.com/dl/cloudsdk/channels/rapid/google-cloud-cli-darwin-arm.tar.gz` (Intel
  Macs: `-darwin-x86_64`), unpack it in the home folder, and run
  `~/google-cloud-sdk/install.sh --quiet --path-update=false`; call `~/google-cloud-sdk/bin/gcloud`
  by its full path.
- Sign in: `gcloud auth login` (opens the browser; they choose their account and click Allow).
- Create, checking each command's result before the next:
  1. A project: `gcloud projects create latchkey-relay-<6 random letters>`; make it the default.
  2. Link billing: `gcloud billing accounts list`, then
     `gcloud billing projects link <project> --billing-account <id>`.
  3. Turn on the services: `gcloud services enable compute.googleapis.com billingbudgets.googleapis.com`.
  4. A fixed address, so the relay's name never changes:
     `gcloud compute addresses create latchkey-ip --region us-central1`.
  5. Open HTTPS only: `gcloud compute firewall-rules create latchkey-https --allow tcp:443
     --target-tags latchkey-relay`.
  6. The server, with the start-up script below:
     `gcloud compute instances create latchkey-relay --zone us-central1-a --machine-type e2-micro
     --image-family ubuntu-2404-lts-amd64 --image-project ubuntu-os-cloud --boot-disk-size 30GB
     --boot-disk-type pd-standard --address latchkey-ip --tags latchkey-relay
     --metadata-from-file startup-script=latchkey-start.sh`.
     The relay's name is the fixed address with dots as dashes plus `.sslip.io` (for 192.0.2.10:
     `192-0-2-10.sslip.io`). Ubuntu 24.04 because its Podman runs Quadlet units; Debian 12's is
     too old.
  7. The alert: `gcloud billing budgets create --billing-account <id> --display-name "Latchkey
     relay" --budget-amount 1USD --threshold-rule percent=1.0` (it emails the account's owner).
- If a step fails because the free server isn't available in that zone, try us-central1-b or
  us-west1-a (and the address in the same region), and say so.

The start-up script (`latchkey-start.sh`), with `<name>`, `<email>`, and `<code>` filled in:

```sh
#!/bin/sh
# Runs at every start; installs Podman once and keeps the relay running and up to date.
set -eu
command -v podman >/dev/null || { apt-get update && apt-get install -y podman; }
mkdir -p /etc/containers/systemd
cat > /etc/containers/systemd/latchkey-relay.container <<'UNIT'
[Container]
Image=ghcr.io/tonimelisma/latchkey-relay:latest
ContainerName=latchkey-relay
AutoUpdate=registry
Notify=true
Volume=latchkey-data:/data
PublishPort=443:8080
Environment=PUBLIC_URL=https://<name> ACME_EMAIL=<email> SETUP_CODE=<code>
[Service]
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl start latchkey-relay.service
systemctl enable --now podman-auto-update.timer
```

## For technical users

Everything above is a default. Oracle Cloud's Always Free server (also $0, harder sign-up),
Railway, or any other host works too. The same image runs on any server or host with a persistent
`/data` volume, under your own domain, with your own email server (`SMTP_*`), behind your own
proxy (`TRUSTED_PROXIES`). See docs/self-hosting.md.
