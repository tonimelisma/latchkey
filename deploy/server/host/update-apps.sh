#!/bin/sh
# latchkey-update-apps: keeps the server's shared apps current without anyone signing in
# (deploy/harden.sh installs it, with a timer every 5 minutes). Nothing outside can reach the
# server to deploy; it fetches public images itself.
# - hackernews: when ghcr.io/tonimelisma/hackernews:latest changes, the app restarts on it; if
#   it isn't healthy within 5 minutes, the previous image comes back and the new one is skipped.
# - Caddy: once a week, the newest caddy:2-alpine, used only if it accepts the Caddyfile and
#   starts; otherwise the previous one comes back.
set -eu
STATE=/var/lib/latchkey-update-apps
mkdir -p "$STATE"
log() { logger -t latchkey-update-apps "$*"; echo "$*"; }

healthy() { # healthy CONTAINER SECONDS: waits for Docker's health check to pass
  _i=0
  while [ "$_i" -lt "$2" ]; do
    case $(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null) in
      healthy | running) return 0 ;;
    esac
    sleep 5
    _i=$((_i + 5))
  done
  return 1
}

# --- hackernews ---
HN=ghcr.io/tonimelisma/hackernews:latest
if docker pull -q "$HN" >/dev/null 2>&1; then
  new=$(docker image inspect --format '{{.Id}}' "$HN")
  old=$(docker inspect --format '{{.Image}}' hackernews-app-1 2>/dev/null || true)
  bad=$(cat "$STATE/hackernews.bad" 2>/dev/null || true)
  if [ "$new" != "$old" ] && [ "$new" != "$bad" ]; then
    log "hackernews: starting new image $new"
    [ -z "$old" ] || docker tag "$old" hackernews:previous
    (cd /opt/hackernews && docker compose up -d --quiet-pull >/dev/null)
    sleep 10
    if healthy hackernews-app-1 300; then
      log "hackernews: new image $new is healthy"
    else
      log "hackernews: new image $new is not healthy; going back to $old"
      echo "$new" >"$STATE/hackernews.bad"
      if [ -n "$old" ]; then
        docker tag hackernews:previous "$HN"
        (cd /opt/hackernews && docker compose up -d >/dev/null)
      fi
    fi
  fi
fi

# --- Caddy, weekly ---
CADDY=caddy:2-alpine
stamp=$STATE/caddy.checked
if [ -z "$(find "$stamp" -mtime -7 2>/dev/null)" ]; then
  touch "$stamp"
  old=$(docker inspect --format '{{.Image}}' caddy 2>/dev/null || true)
  if [ -n "$old" ] && docker pull -q "$CADDY" >/dev/null 2>&1; then
    new=$(docker image inspect --format '{{.Id}}' "$CADDY")
    if [ "$new" != "$old" ]; then
      if docker run --rm --name caddy-check --network none --read-only -v /opt/reverse-proxy/Caddyfile:/etc/caddy/Caddyfile:ro \
        "$CADDY" caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
        docker tag "$old" caddy:previous
        (cd /opt/reverse-proxy && docker compose up -d >/dev/null)
        sleep 10
        if healthy caddy 30; then
          log "caddy: now on $new"
        else
          log "caddy: $new didn't start; going back to $old"
          docker tag caddy:previous "$CADDY"
          (cd /opt/reverse-proxy && docker compose up -d >/dev/null)
        fi
      else
        log "caddy: $new refuses the Caddyfile; staying on $old"
        docker tag "$old" "$CADDY"
      fi
    fi
  fi
fi
docker image prune -f >/dev/null 2>&1 || true
