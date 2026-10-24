#!/bin/sh
# Deploys the relay to a Google Cloud VM that already runs Caddy as its reverse proxy (in
# /opt/reverse-proxy, container "caddy", on the docker network "reverse_proxy").
# Everything about the deployment comes from the repository's .env (gitignored):
#   DEPLOY_HOST       the relay's public host name, e.g. relay.example.com
#   DEPLOY_DNS_ZONE   the Cloudflare zone it lives in, e.g. example.com
#   DEPLOY_VM, DEPLOY_PROJECT, DEPLOY_ZONE   the VM, its Google Cloud project, and its zone
#   ALLOWED_EMAILS    who may sign up (comma-separated)
#   CLOUDFLARE_API_TOKEN (Zone DNS edit), RESEND_API_KEY (send-only; the relay sends with it), and
#   RESEND_ADMIN_KEY (full access; only to set up the sending domain, never copied to the server).
# Safe to rerun: every step is idempotent.
set -eu
cd "$(dirname "$0")/.."
scripts/link-local-files.sh
set -a; . ./.env; set +a
: "${CLOUDFLARE_API_TOKEN:?missing in .env}" "${RESEND_API_KEY:?missing in .env}"
: "${DEPLOY_HOST:?missing in .env}" "${DEPLOY_DNS_ZONE:?missing in .env}" "${ALLOWED_EMAILS:?missing in .env}"
: "${DEPLOY_VM:?missing in .env}" "${DEPLOY_PROJECT:?missing in .env}" "${DEPLOY_ZONE:?missing in .env}"
HOST=$DEPLOY_HOST
ZONE_NAME=$DEPLOY_DNS_ZONE
VM=$DEPLOY_VM; PROJECT=$DEPLOY_PROJECT; ZONE=$DEPLOY_ZONE
TAG=$(git rev-parse --short HEAD)
ssh_vm() { gcloud compute ssh "$VM" --project "$PROJECT" --zone "$ZONE" --quiet --command "$1"; }

echo "• security checks (known vulnerabilities, committed secrets, tidy modules)"
make -C relay security >/dev/null

echo "• DNS and email domain"
IP=$(gcloud compute instances describe "$VM" --project "$PROJECT" --zone "$ZONE" --format='value(networkInterfaces[0].accessConfigs[0].natIP)')
HOST="$HOST" ZONE_NAME="$ZONE_NAME" IP="$IP" python3 deploy/dns_and_email.py

echo "• image $TAG"
docker buildx build -q --platform linux/amd64 -t "latchkey-relay:$TAG" --build-arg VERSION="$TAG" --load relay >/dev/null
docker save "latchkey-relay:$TAG" | gzip | gcloud compute ssh "$VM" --project "$PROJECT" --zone "$ZONE" --quiet \
  --command 'gunzip | sudo docker load -q'

echo "• configuration"
# Files are streamed over SSH straight into root-owned /opt/latchkey: nothing is staged under a
# guessable name in the VM's shared /tmp, and the secrets never touch a local or remote temp file.
ssh_vm 'set -e; sudo install -d -m 755 /opt/latchkey
sudo sh -c "umask 022; cat > /opt/latchkey/docker-compose.yml.new && mv /opt/latchkey/docker-compose.yml.new /opt/latchkey/docker-compose.yml"' \
  < deploy/server/docker-compose.yml
# Caddy reaches the relay over the docker network "reverse_proxy"; the relay believes the client
# address Caddy forwards only from that network's own address ranges (FR-082, research.md).
PROXY_NETS=$(ssh_vm "sudo docker network inspect reverse_proxy --format '{{range .IPAM.Config}}{{.Subnet}},{{end}}'" | tr -d ' \r\n')
PROXY_NETS=${PROXY_NETS%,}
case $PROXY_NETS in
  '' | *[!0-9a-fA-F.:/,]*) echo "FAIL: could not read the reverse_proxy network's address ranges (got '$PROXY_NETS')"; exit 1 ;;
esac
# printf is a shell builtin, so the secret is in no process's arguments; a here-document would
# go through a temp file in some shells.
printf '%s\n' \
  "PUBLIC_URL=https://$HOST" \
  "SMTP_HOST=smtp.resend.com" \
  "SMTP_PORT=465" \
  "SMTP_USER=resend" \
  "SMTP_PASSWORD=$RESEND_API_KEY" \
  "SMTP_FROM=Latchkey <no-reply@$HOST>" \
  "ALLOWED_EMAILS=$ALLOWED_EMAILS" \
  "TRUSTED_PROXIES=$PROXY_NETS" |
  ssh_vm 'sudo sh -c "umask 077; cat > /opt/latchkey/relay.env.new && chmod 600 /opt/latchkey/relay.env.new && mv /opt/latchkey/relay.env.new /opt/latchkey/relay.env"'
SNIPPET=$(sed "s/{{HOST}}/$HOST/" deploy/server/Caddyfile.snippet)
ssh_vm "set -e
grep -q '^$HOST ' /opt/reverse-proxy/Caddyfile || printf '%s\n' '$SNIPPET' >> /opt/reverse-proxy/Caddyfile
cd /opt/latchkey && sudo TAG=$TAG docker compose up -d --remove-orphans --quiet-pull
sudo docker exec caddy caddy reload --config /etc/caddy/Caddyfile
sudo docker image prune -f --filter 'label!=keep' >/dev/null"

echo "• waiting for https://$HOST"
i=0
until curl -fsS "https://$HOST/healthz" >/dev/null 2>&1; do
  i=$((i+1)); [ $i -gt 60 ] && { echo "FAIL: https://$HOST did not come up"; ssh_vm 'sudo docker logs --tail 30 latchkey-relay'; exit 1; }
  sleep 2
done
curl -fsS "https://$HOST/.well-known/oauth-protected-resource/mcp" | grep -q "\"resource\":\"https://$HOST/mcp\""
echo "Deployed $TAG: https://$HOST (connector URL https://$HOST/mcp)"
