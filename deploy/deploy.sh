#!/bin/sh
# Deploys the relay to a Google Cloud VM that already runs Caddy as its reverse proxy (in
# /opt/reverse-proxy, container "caddy", on the docker network "reverse_proxy").
# Everything about the deployment comes from the repository's .env (gitignored):
#   DEPLOY_HOST       the relay's public host name, e.g. relay.example.com
#   DEPLOY_DNS_ZONE   the Cloudflare zone it lives in, e.g. example.com
#   DEPLOY_VM, DEPLOY_PROJECT, DEPLOY_ZONE   the VM, its Google Cloud project, and its zone
#   ALLOWED_EMAILS    who may sign up (comma-separated)
#   CLOUDFLARE_API_TOKEN (Zone DNS edit), RESEND_API_KEY (send-only; the relay sends with it), and
#   RESEND_ADMIN_KEY (full access; only to set up the sending domain, never copied to the server;
#   remove it from .env once the domain is verified).
# Deploys only a clean checkout at origin/main. If the new relay doesn't answer, the previous
# version is started again and the deploy fails. Safe to rerun: every step is idempotent.
# The relay's stored signing keys are encrypted under a key file in /opt/latchkey/keys on the
# server, outside the data volume (see deploy/lib.sh). The first deploy of a version that does
# this stops the relay for a moment and copies the database first: a version from before can't
# read the converted database, so the rollback puts that copy back. Once the new version
# answers, the copy is deleted, and going back to a version from before it is no longer
# possible without signing everyone out (docs/self-hosting.md, "The key file").
# The parts that need no server are tested by deploy/tests/lib_test.sh.
set -eu
LC_ALL=C
export LC_ALL
cd "$(dirname "$0")/.."
. deploy/lib.sh
scripts/link-local-files.sh

echo "• checkout is clean and at origin/main"
require_deployable .
TAG=$(git rev-parse --short HEAD)
check_tag "$TAG"

# The checks run third-party scanners, some fetched at run time, so they run before any key is
# read: .env is not loaded yet, and nothing in it is ever exported.
echo "• security checks (known vulnerabilities, committed secrets and private values, tidy modules)"
make -C relay security >/dev/null

load_env ./.env
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
HOST=$DEPLOY_HOST
ZONE_NAME=$DEPLOY_DNS_ZONE
VM=$DEPLOY_VM PROJECT=$DEPLOY_PROJECT ZONE=$DEPLOY_ZONE
ssh_vm() { gcloud compute ssh "$VM" --project "$PROJECT" --zone "$ZONE" --quiet --command "$1"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' INT TERM HUP

echo "• DNS and email domain"
IP=$(gcloud compute instances describe "$VM" --project "$PROJECT" --zone "$ZONE" --format='value(networkInterfaces[0].accessConfigs[0].natIP)')
check_ip "$IP"
# The two keys exist only in this one command's environment.
HOST="$HOST" ZONE_NAME="$ZONE_NAME" IP="$IP" CLOUDFLARE_API_TOKEN="$CLOUDFLARE_API_TOKEN" \
  RESEND_ADMIN_KEY="${RESEND_ADMIN_KEY-}" python3 deploy/dns_and_email.py

echo "• image $TAG"
docker buildx build -q --platform linux/amd64 -t "latchkey-relay:$TAG" --build-arg VERSION="$TAG" --load relay >/dev/null
upload_image "$TAG" "$tmp"

echo "• configuration"
# The version running now, to go back to if the new one doesn't come up (empty on a first deploy).
PREV=$(ssh_vm "sudo docker inspect --format '{{.Config.Image}}' latchkey-relay 2>/dev/null || true" | tr -d ' \r\n')
PREV=${PREV#latchkey-relay:}
case $PREV in *[!0-9a-f]*) PREV='' ;; esac
# Files are streamed over SSH straight into root-owned /opt/latchkey: nothing is staged under a
# guessable name in the VM's shared /tmp, and the secrets never touch a local or remote temp file.
# The files in use are kept as *.prev for the rollback.
ssh_vm "set -e; sudo install -d -m 755 $REMOTE_DIR
sudo sh -ec 'umask 022; cd $REMOTE_DIR; if [ -f docker-compose.yml ]; then cp -p docker-compose.yml docker-compose.yml.prev; fi
cat > docker-compose.yml.new && mv docker-compose.yml.new docker-compose.yml'" \
  <deploy/server/docker-compose.yml
# Caddy reaches the relay over the docker network "reverse_proxy"; the relay believes the client
# address Caddy forwards only from that network's own address ranges (FR-082, research.md).
PROXY_NETS=$(ssh_vm "sudo docker network inspect reverse_proxy --format '{{range .IPAM.Config}}{{.Subnet}},{{end}}'" | tr -d ' \r\n')
PROXY_NETS=${PROXY_NETS%,}
case $PROXY_NETS in
  '' | *[!0-9a-fA-F.:/,]*) echo "FAIL: could not read the reverse_proxy network's address ranges"; exit 1 ;;
esac
# printf is a shell builtin, so the secret is in no process's arguments; a here-document would
# go through a temp file in some shells. A failure on the VM fails the deploy (the pipeline's
# status is its last command's; printf can't fail).
printf '%s\n' \
  "PUBLIC_URL=https://$HOST" \
  "SMTP_HOST=smtp.resend.com" \
  "SMTP_PORT=465" \
  "SMTP_USER=resend" \
  "SMTP_PASSWORD=$RESEND_API_KEY" \
  "SMTP_FROM=Latchkey <no-reply@$HOST>" \
  "ALLOWED_EMAILS=$ALLOWED_EMAILS" \
  "TRUSTED_PROXIES=$PROXY_NETS" |
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
KEY_STATE=$(key_file_state)
DB_SAVED=''
case $KEY_STATE in
  present) ;;
  absent)
    if [ -n "$PREV" ]; then
      echo "• first start of a version that encrypts the relay's stored keys: stopping the relay and copying its database, for the rollback"
      if ! save_database; then
        ssh_vm "sudo docker start latchkey-relay >/dev/null" || true
        echo "FAIL: could not copy the relay's database on the server; version $PREV keeps running."
        exit 1
      fi
      DB_SAVED=1
    fi
    ;;
  *) echo "FAIL: could not tell whether the server has the relay's key file"; exit 1 ;;
esac

if ! ssh_vm "set -e
cd $REMOTE_DIR && sudo TAG=$TAG docker compose up -d --remove-orphans --quiet-pull
sudo docker exec caddy caddy reload --config /etc/caddy/Caddyfile"; then
  echo "FAIL: version $TAG could not be started."
  roll_back "$HOST" "$TAG" "$PREV" || exit 1
fi

echo "• waiting for https://$HOST"
finish_or_roll_back "$HOST" "$TAG" "$PREV" || exit 1
if [ -n "$DB_SAVED" ]; then
  discard_saved_database || echo "WARNING: could not delete the database copy in $REMOTE_DIR/db-before-keys on the server; it holds the keys unencrypted. Delete it by hand."
fi
[ "$(key_file_state)" = present ] || echo "WARNING: the relay answers, but its key file is not in $REMOTE_DIR/keys/relay on the server."
ssh_vm "sudo docker image prune -f --filter 'label!=keep' >/dev/null" || true
echo "Deployed $TAG: https://$HOST (connector URL https://$HOST/mcp)"
