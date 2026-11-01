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
> [Host-specific cost sentence, see "Hosts".]
>
> Ready?

## Step 2: Hosting account

Follow the host's section below to get the person an account and sign Claude Code in. Say what
they'll see before they see it ("a page will ask for your card; Oracle only checks it and won't
charge it unless you upgrade").

## Step 3: Create the relay

1. Make a setup code: 12 random letters and digits in groups of four (for example
   `K7PQ-M2XD-9RTA`). Keep it; the person needs it in step 4.
2. Create the server or service as the host's section says, with these settings:
   - image `ghcr.io/tonimelisma/latchkey-relay:latest`, kept up to date automatically
   - a persistent volume at `/data`
   - `PUBLIC_URL` = `https://` plus the relay's host name
   - `SETUP_CODE` = the code from 1
   - on a plain server: `ACME_EMAIL` = the person's email (Let's Encrypt's notices), port 443 open
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

> Done. Your relay updates itself when a new version comes out. [Host-specific cost and alert
> sentence.] If you ever move it to another address, you'll make a new passkey and add the
> connector again; everything else stays.

Tell them where things are: the relay's address, the hosting company's page, and that the setup
code is no longer needed (sign-up is now closed).

## Hosts

[NEEDS CLARIFICATION: which is the default (spec 009 FR-904). Both are sketched.]

### Railway

- Cost: "Railway's free plan gives $1 of use a month, which a relay normally stays under. If it
  ever runs out, Railway stops the relay until next month; their Hobby plan is $5 a month."
- Account: open https://railway.com and ask them to sign up with GitHub or email. No card for the
  trial.
- Sign in: `railway login` (opens the browser; they click Allow).
- Create: deploy the Latchkey template (image, volume at `/data`, `SETUP_CODE`, image updates
  on); generate the `*.up.railway.app` domain; set `PUBLIC_URL` from it.

### Oracle Cloud Always Free (Google Cloud if Oracle fails)

- Cost: "Oracle's Always Free server costs nothing. They'll ask for a card to check you're a real
  person; it isn't charged unless you choose to upgrade."
- Account: open https://signup.cloud.oracle.com; they enter name, email, phone, and a card
  (not prepaid or virtual). Ask them to pick the home region nearest to them. If sign-up is
  refused or a later step says "out of capacity", switch to Google Cloud and say why and that it
  costs about $3.65 a month.
- Sign in: install the `oci` command-line tool, then `oci session authenticate` (browser).
- Create: a network with internet access and only port 443 open; one `VM.Standard.E2.1.Micro`
  server with Oracle Linux, a public IPv4 address, and this start-up script, where `<name>` is
  the address with dots as dashes plus `.sslip.io` (for 192.0.2.10: `192-0-2-10.sslip.io`):

  ```yaml
  #cloud-config
  packages: [podman]
  write_files:
    - path: /etc/containers/systemd/latchkey-relay.container
      content: |
        [Container]
        Image=ghcr.io/tonimelisma/latchkey-relay:latest
        AutoUpdate=registry
        Volume=latchkey-data:/data
        PublishPort=443:8080
        Environment=PUBLIC_URL=https://<name> ACME_EMAIL=<email> SETUP_CODE=<code>
        [Service]
        Restart=always
        [Install]
        WantedBy=multi-user.target
  runcmd:
    - systemctl daemon-reload
    - systemctl start latchkey-relay.service
    - systemctl enable --now podman-auto-update.timer
  ```
- Alert: create a budget of $1 that emails them, and say so.
- Idle servers: suggest upgrading the account to pay-as-you-go (still $0 within the free limits)
  so Oracle doesn't reclaim a quiet server; explain it in one sentence and let them decide.

## For technical users

Everything above is a default. The same image runs on any server or host with a persistent
`/data` volume, under your own domain, with your own email server (`SMTP_*`), behind your own
proxy (`TRUSTED_PROXIES`). See docs/self-hosting.md.
