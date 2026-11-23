#!/bin/sh
# latchkey-update-apps: keeps the server's apps current without anyone signing in
# (deploy/harden.sh installs it, with a timer every 5 minutes). Nothing outside can reach the
# server to deploy; it fetches public images itself.
# - the relay: when ghcr.io/tonimelisma/latchkey-relay:latest points at a new image, it is used
#   only if cosign finds it signed by this repository's image workflow on main
#   (.github/workflows/relay-image.yml, keyless: GitHub's identity token, Sigstore's certificate
#   and transparency log). The relay restarts on it with its settings unchanged; if it isn't
#   healthy within 3 minutes (Docker's health check and https://<host>/healthz), the previous
#   version comes back and the new image is skipped. Settings changes come from deploy/deploy.sh.
# - hackernews: when ghcr.io/tonimelisma/hackernews:latest changes, the app restarts on it; if
#   it isn't healthy within 5 minutes, the previous image comes back and the new one is skipped.
# - Caddy: once a week, the newest caddy:2-alpine, used only if it accepts the Caddyfile and
#   starts; otherwise the previous one comes back.
set -eu
STATE=${LATCHKEY_UPDATE_STATE:-/var/lib/latchkey-update-apps}
RELAY_DIR=${LATCHKEY_RELAY_DIR:-/opt/latchkey}
mkdir -p "$STATE"
log() { logger -t latchkey-update-apps "$*"; echo "$*"; }
# One run at a time, and never while deploy/deploy.sh restarts the relay (it takes this lock too).
exec 9>"${LATCHKEY_UPDATE_LOCK:-/run/latchkey-update-apps.lock}"
flock -n 9 || exit 0
# once NAME VALUE MESSAGE: logs MESSAGE only when VALUE is new for NAME, so a problem that lasts
# is reported once, not every 5 minutes.
once() {
  [ "$(cat "$STATE/$1" 2>/dev/null || true)" = "$2" ] && return 0
  printf '%s\n' "$2" >"$STATE/$1"
  log "$3"
}

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

# --- the relay ---
RELAY=ghcr.io/tonimelisma/latchkey-relay
RELAY_SIGNER=https://github.com/tonimelisma/latchkey/.github/workflows/relay-image.yml@refs/heads/main
RELAY_ISSUER=https://token.actions.githubusercontent.com

# relay_digest: the digest ghcr.io's "latest" points at, from the registry's own answer (public:
# an anonymous pull token), or nothing.
relay_digest() {
  _token=$(curl -fsS --max-time 20 "https://ghcr.io/token?scope=repository:tonimelisma/latchkey-relay:pull" 2>/dev/null |
    sed -n 's/.*"token" *: *"\([^"]*\)".*/\1/p') || return 1
  [ -n "$_token" ] || return 1
  curl -fsS -I --max-time 20 -H "Authorization: Bearer $_token" \
    -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
    "https://ghcr.io/v2/tonimelisma/latchkey-relay/manifests/latest" 2>/dev/null |
    tr -d '\r' | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: *//p' | head -1
}

# relay_answers: the relay's public address answers /healthz (through Caddy), within a minute.
relay_answers() {
  _url=$(sed -n 's/^PUBLIC_URL=//p' "$RELAY_DIR/relay.env" | tail -1 | tr -d "'\"")
  [ -n "$_url" ] || return 0
  _i=0
  until curl -fsS --max-time 10 "$_url/healthz" >/dev/null 2>&1; do
    _i=$((_i + 1))
    [ "$_i" -lt 12 ] || return 1
    sleep 5
  done
}

relay_update() {
  # Not configured here yet (deploy/deploy.sh writes these): nothing to update.
  [ -f "$RELAY_DIR/docker-compose.yml" ] && [ -f "$RELAY_DIR/relay.env" ] || return 0
  command -v cosign >/dev/null 2>&1 || { once relay.problem no-cosign "relay: cosign is missing, so no new version can be checked; run deploy/harden.sh"; return 0; }
  digest=$(relay_digest || true)
  case $digest in
    sha256:*) case ${digest#sha256:} in *[!0-9a-f]* | '') return 0 ;; esac ;;
    *) return 0 ;; # the registry didn't answer; the next run tries again
  esac
  [ "${#digest}" = 71 ] || return 0
  [ "$digest" != "$(cat "$STATE/relay.digest" 2>/dev/null || true)" ] || return 0
  [ "$digest" != "$(cat "$STATE/relay.bad" 2>/dev/null || true)" ] || return 0
  if ! out=$(TUF_ROOT="$STATE/sigstore" cosign verify --certificate-identity "$RELAY_SIGNER" \
    --certificate-oidc-issuer "$RELAY_ISSUER" "$RELAY@$digest" 2>&1 >/dev/null); then
    once relay.problem "unsigned $digest" "relay: $digest isn't signed by the image workflow on main; not used: $(printf '%s' "$out" | tail -1 | cut -c1-300)"
    return 0
  fi
  docker pull -q "$RELAY@$digest" >/dev/null 2>&1 || return 0
  rev=$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$RELAY@$digest" 2>/dev/null || true)
  case $rev in *[!0-9a-f]* | '') once relay.problem "norev $digest" "relay: $digest names no commit; not used"; return 0 ;; esac
  [ "${#rev}" = 40 ] || { once relay.problem "norev $digest" "relay: $digest names no commit; not used"; return 0; }
  tag=$(printf '%s' "$rev" | cut -c1-12)
  docker tag "$RELAY@$digest" "latchkey-relay:$tag" || return 0
  prev=$(docker inspect --format '{{.Config.Image}}' latchkey-relay 2>/dev/null || true)
  prev=${prev#latchkey-relay:}
  case $prev in *[!0-9a-f]*) prev='' ;; esac
  if [ "$prev" = "$tag" ]; then
    printf '%s\n' "$digest" >"$STATE/relay.digest"
    return 0
  fi
  # A relay that has run without its key file can't be updated blindly (.claude/rules/relay.md):
  # deploy/deploy.sh prepares it.
  if [ -n "$prev" ] && [ ! -f "$RELAY_DIR/keys/relay/relay.key" ]; then
    once relay.problem "nokey $digest" "relay: no key file in $RELAY_DIR/keys/relay; not updating (run the infra workflow's configure)"
    return 0
  fi
  log "relay: starting $tag ($digest)"
  (cd "$RELAY_DIR" && TAG=$tag docker compose up -d --remove-orphans >/dev/null 2>&1) || true
  sleep 10
  if healthy latchkey-relay 180 && [ "$(docker inspect --format '{{.Config.Image}}' latchkey-relay 2>/dev/null)" = "latchkey-relay:$tag" ] && relay_answers; then
    log "relay: $tag is healthy"
    printf '%s\n' "$digest" >"$STATE/relay.digest"
    rm -f "$STATE/relay.problem"
    # The running version and the one before stay (the rollback needs it); older ones go.
    docker images latchkey-relay --format '{{.Tag}}' | while read -r t; do
      [ "$t" = "$tag" ] || [ "$t" = "$prev" ] || docker rmi "latchkey-relay:$t" >/dev/null 2>&1 || true
    done
  else
    log "relay: $tag is not healthy; going back to ${prev:-nothing}: $(docker logs --tail 3 latchkey-relay 2>&1 | tr '\n' ' ' | cut -c1-300)"
    printf '%s\n' "$digest" >"$STATE/relay.bad"
    if [ -n "$prev" ]; then
      (cd "$RELAY_DIR" && TAG=$prev docker compose up -d --remove-orphans >/dev/null 2>&1) || log "relay: couldn't start $prev again"
    fi
  fi
}
relay_update

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
      # Scratch /data and /config: validating opens the access log and Caddy's storage there.
      if out=$(docker run --rm --name caddy-check --network none --read-only --tmpfs /data --tmpfs /config \
        -v /opt/reverse-proxy/Caddyfile:/etc/caddy/Caddyfile:ro \
        "$CADDY" caddy validate --config /etc/caddy/Caddyfile 2>&1); then
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
        log "caddy: $new refuses the Caddyfile; staying on $old: $(printf '%s' "$out" | tail -1 | cut -c1-300)"
        docker tag "$old" "$CADDY"
      fi
    fi
  fi
fi
docker image prune -f >/dev/null 2>&1 || true
