# Spec 009 research: easy relay setup

Checked 2026-10-31. Prices and free tiers change; each value has its source. "Unverified" means
no primary source was found.

## What the relay needs from a host

One container (ghcr.io image) with a persistent `/data` volume (SQLite and the key file), always
on (the Mac holds a WebSocket, pinged every 15 s), reachable over HTTPS from Anthropic's cloud
(IPv4: Anthropic's connector traffic is reportedly IPv4 only, secondary source
https://zuplo.com/learn/mcp/authentication/anthropic-managed-agents), and a stable host name
(the passkey domain is `PUBLIC_URL`'s host, `relay/internal/account/account.go`). Its own HTTPS
uses autocert with TLS-ALPN on port 443 only (`relay/cmd/relay/main.go`).

## Free servers and cards

"Don't all clouds have a free server?" No. Only Oracle's is free for good with a public IPv4
address, and every free server needs a card (Azure for Students excepted).

| Provider | Card | Free for good | Runs the relay | Notes |
|---|---|---|---|---|
| Oracle Always Free | Yes, and phone; no prepaid, virtual, or PIN debit cards | Yes | Yes, $0 | Up to 2 AMD micro VMs or Arm A1; 200 GB disk; IPv4 included; idle VMs (7 days under 20% CPU and network) may be reclaimed on unupgraded accounts; free Arm allowance halved in 2026. https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm, https://www.oracle.com/cloud/free/faq/, https://linuxiac.com/oracle-quietly-cuts-free-tier-ampere-a1-resources-in-half/ |
| Google Cloud e2-micro | Yes (billing account) | Yes, but the IPv4 address costs $0.005/h ≈ $3.65/mo | Yes | us-west1, us-central1, us-east1; 30 GB disk; 1 GB egress a month. https://docs.cloud.google.com/free/docs/free-cloud-features, https://cloud.google.com/vpc/network-pricing |
| AWS Free plan | Yes (unverified) | No: credits, account closes after 6 months | Temporarily | https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/free-tier-plans.html |
| Azure free account | Yes (unverified) | No: 12 months | Temporarily | https://azure.microsoft.com/en-us/pricing/free-services |
| Azure for Students | No | $100 a year while a student | Students only | https://azure.microsoft.com/en-us/free/students |
| Railway Trial / Free | No (forum answer) | $1 of usage a month after a 30-day trial | Probably, if usage stays under $1 | 0.5 GB volume; `*.up.railway.app`; trial volumes may be deleted 30 days after credits expire; Hobby $5/mo. https://docs.railway.com/pricing/plans, https://docs.railway.com/pricing/free-trial, https://station.railway.com/questions/i-don-t-have-a-credit-card-9833999e |
| Render, Koyeb free | Sometimes / yes | Yes | No | Sleep after 15 min / 1 h; no disk on free. https://render.com/docs/free, https://www.koyeb.com/docs/faqs/pricing |
| Fly.io | Yes after trial | No | Paid, ≈ $2.35/mo | https://docs.fly.io/about/pricing |
| Cloud Run, Cloudflare, DO App Platform | — | — | No | No disk for SQLite, or disk wiped on sleep. https://docs.cloud.google.com/run/docs/triggering/websockets, https://developers.cloudflare.com/containers/platform-details/, https://docs.digitalocean.com/products/app-platform/details/limits/ |

No cloud offers a hard spending cap on these; Oracle's and Google's budgets only send email
(https://docs.oracle.com/en-us/iaas/Content/Billing/Concepts/budgetsoverview.htm,
https://docs.cloud.google.com/billing/docs/how-to/budgets).

## Names and certificates

No free server comes with a name Let's Encrypt will certify:
- Google's `<ip>.bc.googleusercontent.com`: refused, Google's CAA allows only `pki.goog`
  (https://community.letsencrypt.org/t/can-no-longer-obtain-a-certificate-for-the-googleusercontent-com-domain/226768).
- AWS `ec2-….amazonaws.com`: refused by Let's Encrypt policy
  (https://community.letsencrypt.org/t/policy-forbids-issuing-to-my-name/33548).
- Oracle: only private `oraclevcn.com` names (https://docs.oracle.com/iaas/Content/Network/Concepts/dns.htm).
- Azure `<label>.<region>.cloudapp.azure.com`: free with the IP and likely certifiable
  (unverified), but Azure is free for 12 months only.

Free names that need nothing else:
- **sslip.io / nip.io**: no sign-up, the name is the IP (`1-2-3-4.sslip.io`); Let's Encrypt
  raised their limit to 250,000; not on the Public Suffix List, so other sslip.io sites could set
  cookies on the parent name (hence FR-912). https://nip.io/
- **DuckDNS** (sign in with Google or GitHub) and **deSEC** (email): on the Public Suffix List.
  https://www.duckdns.org/faqs.jsp, https://desec.io/
- Platform names `*.up.railway.app`, `*.onrender.com`, `*.fly.dev`: on the list.
  https://publicsuffix.org/list/public_suffix_list.dat

Passkeys are bound to the host name (https://developer.mozilla.org/en-US/docs/Web/API/PublicKeyCredentialCreationOptions):
a name change means new passkeys and a new connector URL, so the IP behind an sslip.io name
must stay fixed (Oracle's ephemeral IP stays until the VM is terminated).

## First-run claim without email

Comparable self-hosted apps: Immich and Uptime Kuma make the first visitor the admin; Home
Assistant's onboarding creates the owner; Vaultwarden locks its admin page with a token; Jenkins
prints a one-time unlock code; Portainer shuts down if no admin is created within 5 minutes.
https://docs.immich.app/install/post-install, https://www.home-assistant.io/getting-started/onboarding,
https://github.com/dani-garcia/vaultwarden/wiki/Enabling-admin-page

## Updates

- Podman `auto-update` with `AutoUpdate=registry` checks daily (systemd timer) and rolls back
  when the restarted container fails; rollback is reliable when the container reports ready
  (sd_notify) or has a health check. https://docs.podman.io/en/latest/markdown/podman-auto-update.1.html
- Watchtower (Docker) was archived on 2025-12-17.
  https://linuxiac.com/docker-update-tool-watchtower-reaches-end-of-maintenance/
- Railway redeploys on a new image tag in a chosen time window.
  https://docs.railway.com/deployments/image-auto-updates

## What Claude Code can drive

- Oracle: `oci` CLI (Homebrew on a Mac; Homebrew needs an admin at first), browser sign-in with
  `oci session authenticate` (token 1 h, refreshable to 24 h).
  https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm, https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/clitoken.htm
- Google: SDK installs into the home folder; `gcloud init` signs in through the browser; official
  remote MCP servers for Compute Engine and gcloud. https://docs.cloud.google.com/sdk/docs/install-sdk,
  https://docs.cloud.google.com/compute/docs/use-compute-engine-mcp
- Railway: local MCP (`railway mcp local`) has `deploy_template`, `create_volume`,
  `set_variables`, `generate_domain`. https://docs.railway.com/reference/mcp-server
- Plans: custom connectors on every plan (Free: one only; Team and Enterprise: owners add them);
  Claude Code in Pro and Max.
  https://support.claude.com/en/articles/11175166-getting-started-with-custom-connectors-using-remote-mcp,
  https://support.claude.com/en/articles/11145838-use-claude-code-with-your-pro-or-max-plan
