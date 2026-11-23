#!/bin/sh
# Applies the relay's configuration on the Google Cloud VM that already runs Caddy as its reverse
# proxy (in /opt/reverse-proxy, container "caddy"), set up by deploy/harden.sh: Caddy and the relay
# share the docker network "latchkey-front", and no other container is on it.
# New relay versions don't come through here: CI publishes each one to ghcr.io, signed
# (.github/workflows/relay-image.yml), and the server's own updater (latchkey-update-apps) checks
# the signature, switches to it and goes back if it isn't healthy. This script is for what changes
# rarely: the relay's settings (relay.env), its compose file, its Caddy block, DNS and the email
# domain. It runs in the infra workflow (.github/workflows/infra.yml, task "configure"), which a
# session starts with repository_dispatch; it restarts the relay on the version it is running
# (or, on a first deploy, has the updater start the newest signed one).
# The settings come from the repository's .env when there is one (gitignored), else from the
# environment (the workflow's secrets):
#   DEPLOY_HOST       the relay's public host name, e.g. relay.example.com
#   DEPLOY_DNS_ZONE   the Cloudflare zone it lives in, e.g. example.com
#   DEPLOY_VM, DEPLOY_PROJECT, DEPLOY_ZONE   the VM, its Google Cloud project, and its zone
#   ALLOWED_EMAILS    who may sign up (comma-separated)
#   OPERATOR_NAME, OPERATOR_CONTACT   optional, both or neither: who runs the relay and the email
#                     address for questions; with them the relay publishes its terms of service
#                     and privacy policy (docs/self-hosting.md)
#   OPERATOR_LAW, OPERATOR_PROVIDERS, BACKUP_DAYS   optional: the law the terms are under, the
#                     companies that handle the relay's data, and how many days backups are kept.
#                     Free text goes in single quotes: OPERATOR_LAW='California, USA'
#   CLOUDFLARE_API_TOKEN (Zone DNS edit), RESEND_API_KEY (send-only; the relay sends with it), and
#   RESEND_ADMIN_KEY (full access; only to set up the sending domain, never copied to the server;
#   remove it once the domain is verified).
# Applies only a clean checkout of a commit on main. If the relay doesn't answer with the new
# settings, the previous settings come back and the deploy fails. Safe to rerun: every step is
# idempotent. The parts that need no server are tested by deploy/tests/lib_test.sh.
set -eu
# One deploy at a time: on a Mac by a lock file, waiting up to 15 minutes for another
# (2026-11-04); in GitHub Actions by the workflow's concurrency group.
LOCK=$HOME/Library/Caches/net.melisma.latchkey.deploy.lock
if [ -x /usr/bin/lockf ] && [ "${LATCHKEY_DEPLOY_LOCKED:-}" != "$LOCK" ]; then
  LATCHKEY_DEPLOY_LOCKED=$LOCK exec /usr/bin/lockf -t 900 "$LOCK" "$0" "$@"
fi
LC_ALL=C
export LC_ALL
cd "$(dirname "$0")/.."
. deploy/lib.sh
scripts/link-local-files.sh

echo "• checkout is clean and on origin/main"
require_deployable .

load_settings ./.env DEPLOY_HOST DEPLOY_DNS_ZONE DEPLOY_VM DEPLOY_PROJECT DEPLOY_ZONE ALLOWED_EMAILS \
  OPERATOR_NAME OPERATOR_CONTACT OPERATOR_LAW OPERATOR_PROVIDERS BACKUP_DAYS \
  CLOUDFLARE_API_TOKEN RESEND_API_KEY RESEND_ADMIN_KEY
: "${CLOUDFLARE_API_TOKEN:?missing in .env}" "${RESEND_API_KEY:?missing in .env}"
: "${DEPLOY_HOST:?missing in .env}" "${DEPLOY_DNS_ZONE:?missing in .env}" "${ALLOWED_EMAILS:?missing in .env}"
: "${DEPLOY_VM:?missing in .env}" "${DEPLOY_PROJECT:?missing in .env}" "${DEPLOY_ZONE:?missing in .env}"
check_host DEPLOY_HOST "$DEPLOY_HOST"
check_host DEPLOY_DNS_ZONE "$DEPLOY_DNS_ZONE"
check_host DEPLOY_VM "$DEPLOY_VM"
check_host DEPLOY_PROJECT "$DEPLOY_PROJECT"
check_host DEPLOY_ZONE "$DEPLOY_ZONE"
check_emails "$ALLOWED_EMAILS"
check_secret CLOUDFLARE_API_TOKEN "$CLOUDFLARE_API_TOKEN"
check_secret RESEND_API_KEY "$RESEND_API_KEY"
[ -z "${RESEND_ADMIN_KEY-}" ] || check_secret RESEND_ADMIN_KEY "$RESEND_ADMIN_KEY"
check_operator "${OPERATOR_NAME-}" "${OPERATOR_CONTACT-}" "${OPERATOR_LAW-}" "${OPERATOR_PROVIDERS-}" "${BACKUP_DAYS-}"
HOST=$DEPLOY_HOST
ZONE_NAME=$DEPLOY_DNS_ZONE
VM=$DEPLOY_VM PROJECT=$DEPLOY_PROJECT ZONE=$DEPLOY_ZONE
# SSH reaches the VM only through Google's IAP tunnel (deploy/harden.sh).
ssh_vm() { vm_ssh "$VM" "$PROJECT" "$ZONE" "$1"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' INT TERM HUP

echo "• DNS and email domain"
IP=$(gcloud compute instances describe "$VM" --project "$PROJECT" --zone "$ZONE" --format='value(networkInterfaces[0].accessConfigs[0].natIP)')
check_ip "$IP"
mask "$IP"
# The two keys exist only in this one command's environment.
HOST="$HOST" ZONE_NAME="$ZONE_NAME" IP="$IP" CLOUDFLARE_API_TOKEN="$CLOUDFLARE_API_TOKEN" \
  RESEND_ADMIN_KEY="${RESEND_ADMIN_KEY-}" python3 deploy/dns_and_email.py

echo "• configuration"
# The version running now: it restarts with the new settings, and with the previous settings if it
# doesn't answer (empty on a first deploy).
PREV=$(ssh_vm "sudo docker inspect --format '{{.Config.Image}}' latchkey-relay 2>/dev/null || true" | tr -d ' \r\n')
PREV=${PREV#latchkey-relay:}
case $PREV in *[!0-9a-f]*) PREV='' ;; esac
TAG=$PREV
# Files are streamed over SSH straight into root-owned /opt/latchkey: nothing is staged under a
# guessable name in the VM's shared /tmp, and the secrets never touch a local or remote temp file.
# The files in use are kept as *.prev for the rollback.
ssh_vm "set -e; sudo install -d -m 755 $REMOTE_DIR
sudo sh -ec 'umask 022; cd $REMOTE_DIR; if [ -f docker-compose.yml ]; then cp -p docker-compose.yml docker-compose.yml.prev; fi
cat > docker-compose.yml.new && mv docker-compose.yml.new docker-compose.yml'" \
  <deploy/server/docker-compose.yml
# Caddy reaches the relay over the docker network "latchkey-front"; the relay believes the client
# address Caddy forwards only from that network's own address ranges (FR-082, research.md).
PROXY_NETS=$(ssh_vm "sudo docker network inspect latchkey-front --format '{{range .IPAM.Config}}{{.Subnet}},{{end}}'" | tr -d ' \r\n')
PROXY_NETS=${PROXY_NETS%,}
case $PROXY_NETS in
  '' | *[!0-9a-fA-F.:/,]*) echo "FAIL: could not read the latchkey-front network's address ranges"; exit 1 ;;
esac
# printf is a shell builtin, so the secret is in no process's arguments; a here-document would
# go through a temp file in some shells. A failure on the VM fails the deploy (the pipeline's
# status is its last command's; printf can't fail).
# The operator's details (checked above) follow, each only when set.
{
  printf '%s\n' \
    "PUBLIC_URL=https://$HOST" \
    "SMTP_HOST=smtp.resend.com" \
    "SMTP_PORT=465" \
    "SMTP_USER=resend" \
    "SMTP_PASSWORD=$RESEND_API_KEY" \
    "SMTP_FROM=Latchkey <no-reply@$HOST>" \
    "ALLOWED_EMAILS=$ALLOWED_EMAILS" \
    "TRUSTED_PROXIES=$PROXY_NETS"
  operator_env_lines "${OPERATOR_NAME-}" "${OPERATOR_CONTACT-}" "${OPERATOR_LAW-}" "${OPERATOR_PROVIDERS-}" "${BACKUP_DAYS-}"
} |
  ssh_vm "sudo sh -ec 'umask 077; cd $REMOTE_DIR; if [ -f relay.env ]; then cp -p relay.env relay.env.prev; fi
cat > relay.env.new && chmod 600 relay.env.new && mv relay.env.new relay.env'"

# The relay's site block in the shared Caddyfile is replaced with the current snippet. The file is
# written in place (it may be mounted into the Caddy container as a single file), checked by Caddy
# itself, and put back as it was if Caddy refuses it.
sed "s/{{HOST}}/$HOST/g" deploy/server/Caddyfile.snippet >"$tmp/snippet"
ssh_vm "sudo cat $CADDYFILE" >"$tmp/Caddyfile.old"
if [ ! -s "$tmp/Caddyfile.old" ] || grep -q "$(printf '\r')" "$tmp/Caddyfile.old"; then
  echo "FAIL: could not read the server's Caddyfile"
  exit 1
fi
caddyfile_with_block "$HOST" "$tmp/snippet" <"$tmp/Caddyfile.old" >"$tmp/Caddyfile.new"
cmp -s "$tmp/Caddyfile.old" "$tmp/Caddyfile.new" || install_caddyfile "$tmp/Caddyfile.new"

echo "• key folder"
prepare_key_dir
case $(key_file_state) in
  present | absent) ;;
  *) echo "FAIL: could not tell whether the server has the relay's key file"; exit 1 ;;
esac

# The relay restarts under the server updater's lock, so the two never change it at once.
if [ -n "$TAG" ]; then
  echo "• restarting version $TAG with the new settings"
  if ! ssh_vm "set -e
cd $REMOTE_DIR && sudo flock -w 900 $UPDATE_LOCK env TAG=$TAG docker compose up -d --remove-orphans --quiet-pull
sudo docker exec caddy caddy reload --config /etc/caddy/Caddyfile"; then
    echo "FAIL: version $TAG could not be started with the new settings."
    roll_back "$HOST" "$TAG" "$PREV" || exit 1
  fi
else
  echo "• first deploy: the server's updater starts the newest signed version"
  ssh_vm "sudo docker exec caddy caddy reload --config /etc/caddy/Caddyfile && sudo /usr/local/sbin/latchkey-update-apps" ||
    { echo "FAIL: the server's updater couldn't start the relay (has deploy/harden.sh run?)"; exit 1; }
fi

echo "• waiting for https://$HOST"
finish_or_roll_back "$HOST" "${TAG:-new}" "$PREV" || exit 1
[ "$(key_file_state)" = present ] || echo "WARNING: the relay answers, but its key file is not in $REMOTE_DIR/keys/relay on the server."
echo "Configured: https://$HOST (connector URL https://$HOST/mcp)"
