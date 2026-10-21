#!/bin/sh
# Deploys the relay to https://relay.example.com on my-vm (GCP project my-gcp-project).
# Needs in the repository's .env (gitignored): CLOUDFLARE_API_TOKEN (Zone DNS edit on
# example.com) and RESEND_API_KEY (full access). Safe to rerun: every step is idempotent.
set -eu
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
: "${CLOUDFLARE_API_TOKEN:?missing in .env}" "${RESEND_API_KEY:?missing in .env}"
HOST=relay.example.com
ZONE_NAME=example.com
VM=my-vm; PROJECT=my-gcp-project; ZONE=my-zone
ALLOWED_EMAILS=${ALLOWED_EMAILS:-owner@example.com}
TAG=$(git rev-parse --short HEAD)
ssh_vm() { gcloud compute ssh "$VM" --project "$PROJECT" --zone "$ZONE" --quiet --command "$1"; }

echo "• DNS and email domain"
IP=$(gcloud compute instances describe "$VM" --project "$PROJECT" --zone "$ZONE" --format='value(networkInterfaces[0].accessConfigs[0].natIP)')
HOST="$HOST" ZONE_NAME="$ZONE_NAME" IP="$IP" python3 deploy/dns_and_email.py

echo "• image $TAG"
docker buildx build -q --platform linux/amd64 -t "latchkey-relay:$TAG" --build-arg VERSION="$TAG" --load relay >/dev/null
docker save "latchkey-relay:$TAG" | gzip | gcloud compute ssh "$VM" --project "$PROJECT" --zone "$ZONE" --quiet \
  --command 'gunzip | sudo docker load -q'

echo "• configuration"
gcloud compute scp --project "$PROJECT" --zone "$ZONE" --quiet deploy/my-vm/docker-compose.yml "$VM:/tmp/latchkey-compose.yml" >/dev/null
umask 077
ENVFILE=$(mktemp)
cat > "$ENVFILE" <<ENV
PUBLIC_URL=https://$HOST
SMTP_HOST=smtp.resend.com
SMTP_PORT=465
SMTP_USER=resend
SMTP_PASSWORD=$RESEND_API_KEY
SMTP_FROM=Latchkey <no-reply@$HOST>
ALLOWED_EMAILS=$ALLOWED_EMAILS
ENV
gcloud compute scp --project "$PROJECT" --zone "$ZONE" --quiet "$ENVFILE" "$VM:/tmp/latchkey-relay.env" >/dev/null
rm -f "$ENVFILE"
SNIPPET=$(cat deploy/my-vm/Caddyfile.snippet)
ssh_vm "set -e
sudo mkdir -p /opt/latchkey
sudo mv /tmp/latchkey-compose.yml /opt/latchkey/docker-compose.yml
sudo install -m 600 /tmp/latchkey-relay.env /opt/latchkey/relay.env && rm -f /tmp/latchkey-relay.env
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
