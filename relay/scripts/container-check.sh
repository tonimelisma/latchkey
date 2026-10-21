#!/bin/sh
# Checks the relay container the way a self-hoster runs it (FR-080): only the documented
# environment variables and one volume; health, discovery, the 401 challenge, and that data
# survives a restart.
set -eu
cd "$(dirname "$0")/.."
IMAGE=${IMAGE:-latchkey-relay:check}
NAME=latchkey-relay-check
VOL=latchkey-relay-check-data
PORT=${PORT:-18443}
docker build -q -t "$IMAGE" . >/dev/null
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker volume rm "$VOL" >/dev/null 2>&1 || true
trap 'docker rm -f "$NAME" >/dev/null 2>&1; docker volume rm "$VOL" >/dev/null 2>&1' EXIT

start() {
  docker run -d --name "$NAME" -p "127.0.0.1:$PORT:8080" -v "$VOL:/data" \
    -e PUBLIC_URL="http://localhost:$PORT" -e SMTP_HOST=smtp.invalid -e SMTP_PORT=587 \
    -e SMTP_FROM="Latchkey <relay@example.com>" "$IMAGE" >/dev/null
  i=0
  until [ "$(docker inspect -f '{{.State.Health.Status}}' "$NAME" 2>/dev/null)" = healthy ] || [ $i -ge 40 ]; do
    curl -fsS "http://localhost:$PORT/healthz" >/dev/null 2>&1 && break
    i=$((i+1)); sleep 0.5
  done
  curl -fsS "http://localhost:$PORT/healthz" >/dev/null
}

fail() { echo "FAIL: $*"; docker logs "$NAME" 2>&1 | tail -20; exit 1; }

start
echo "• container started with only environment variables and a volume"
curl -fsS "http://localhost:$PORT/.well-known/oauth-protected-resource/mcp" | grep -q "\"resource\":\"http://localhost:$PORT/mcp\"" \
  || fail "protected resource metadata"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://localhost:$PORT/mcp" -H 'Content-Type: application/json' -d '{}')
[ "$code" = 401 ] || fail "/mcp without a token returned $code, want 401"
hdr=$(curl -s -D - -o /dev/null -X POST "http://localhost:$PORT/mcp" -H 'Content-Type: application/json' -d '{}' | grep -i '^www-authenticate')
echo "$hdr" | grep -q 'resource_metadata=' || fail "missing WWW-Authenticate challenge"
echo "• discovery and the 401 challenge work"

reg=$(curl -fsS -X POST "http://localhost:$PORT/register" -H 'Content-Type: application/json' \
  -d '{"client_name":"check","redirect_uris":["https://claude.ai/api/mcp/auth_callback"],"token_endpoint_auth_method":"none"}')
client=$(echo "$reg" | sed -n 's/.*"client_id":"\([^"]*\)".*/\1/p')
[ -n "$client" ] || fail "registration"
docker restart "$NAME" >/dev/null
sleep 1
start 2>/dev/null || curl -fsS "http://localhost:$PORT/healthz" >/dev/null || fail "restart"
code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/authorize?response_type=code&client_id=$client&redirect_uri=https%3A%2F%2Fclaude.ai%2Fapi%2Fmcp%2Fauth_callback&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256&state=abcdefgh")
[ "$code" = 302 ] || fail "registered client lost after restart (authorize returned $code)"
echo "• data survives a restart (registered client still known)"
echo "• image size: $(docker image inspect -f '{{.Size}}' "$IMAGE" | awk '{printf "%.1f MB", $1/1000000}')"
echo PASS
