#!/bin/sh
# Tests for the relay part of deploy/server/host/update-apps.sh, the server's own updater, with
# docker, cosign, curl and logger replaced by stand-ins: no server, no network.
# Run: deploy/tests/update_apps_test.sh (or `make -C relay script-tests`).
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (wanted '$3', got '$2')"; fi; }

mkdir -p "$work/bin" "$work/relay/keys/relay" "$work/state"
touch "$work/relay/docker-compose.yml" "$work/relay/keys/relay/relay.key"
echo "PUBLIC_URL=https://relay.example.com" >"$work/relay/relay.env"
D1=sha256:$(printf '1%.0s' $(seq 64))
D2=sha256:$(printf '2%.0s' $(seq 64))
R1=$(printf 'a%.0s' $(seq 40))
R2=$(printf 'b%.0s' $(seq 40))

cat >"$work/bin/curl" <<'STUB'
#!/bin/sh
for a in "$@"; do last=$a; done
case $last in
*/token*) echo '{"token":"anon"}' ;;
*/manifests/latest) printf 'HTTP/2 200\r\ndocker-content-digest: %s\r\n\r\n' "$(cat "$W/latest")" ;;
*/healthz) [ "$(cat "$W/answers")" = yes ] ;;
*) exit 1 ;;
esac
STUB
cat >"$work/bin/cosign" <<'STUB'
#!/bin/sh
echo "cosign $*" >>"$W/log"
for a in "$@"; do last=$a; done
grep -qxF "${last#*@}" "$W/signed" 2>/dev/null || { echo "no matching signatures" >&2; exit 1; }
STUB
cat >"$work/bin/docker" <<'STUB'
#!/bin/sh
echo "docker $*" >>"$W/log"
case "$1 $2" in
"pull -q") case $3 in ghcr.io/tonimelisma/latchkey-relay@*) exit 0 ;; *) exit 1 ;; esac ;;
"image inspect") case $5 in *"$(sed -n 1p "$W/d1")") cat "$W/rev1" ;; *) cat "$W/rev2" ;; esac ;;
"tag "*) ;;
"compose up") [ -n "${TAG-}" ] && echo "latchkey-relay:$TAG" >"$W/running" ;;
"images "*) printf '%s\n' bbbbbbbbbbbb aaaaaaaaaaaa 000000000000 ;;
"rmi "*) ;;
"logs "*) echo "relay log line" ;;
"inspect --format")
  case $3 in
  *Health*) [ "$4" = latchkey-relay ] && head -1 "$W/health" ;;
  *Config.Image*) [ "$4" = latchkey-relay ] && cat "$W/running" 2>/dev/null ;;
  *) exit 1 ;;
  esac ;;
*) exit 1 ;;
esac
STUB
printf '#!/bin/sh\n' >"$work/bin/logger"
printf '#!/bin/sh\n' >"$work/bin/sleep"
chmod +x "$work/bin/"*
echo "$D1" >"$work/d1"
echo "$R1" >"$work/rev1"
echo "$R2" >"$work/rev2"

run() {
  : >"$work/log"
  W=$work PATH="$work/bin:$PATH" LATCHKEY_UPDATE_STATE="$work/state" LATCHKEY_RELAY_DIR="$work/relay" \
    LATCHKEY_UPDATE_LOCK="$work/lock" sh "$root/deploy/server/host/update-apps.sh" >"$work/out" 2>&1
}
export W

# The relay runs 000000000000; latest is a new, signed image of commit R1.
echo "latchkey-relay:000000000000" >"$work/running"
echo "$D1" >"$work/latest"
echo "$D1" >"$work/signed"
echo healthy >"$work/health"
echo yes >"$work/answers"
run
is "a signed new image is used" "$(cat "$work/running")" "latchkey-relay:aaaaaaaaaaaa"
grep -q -- "--certificate-identity https://github.com/tonimelisma/latchkey/.github/workflows/relay-image.yml@refs/heads/main" "$work/log" &&
  ok "the signature must be the image workflow's on main" || bad "the signature must be the image workflow's on main"
grep -q -- "--certificate-oidc-issuer https://token.actions.githubusercontent.com" "$work/log" &&
  ok "issued for GitHub Actions" || bad "issued for GitHub Actions"
grep -q "docker pull -q ghcr.io/tonimelisma/latchkey-relay@$D1" "$work/log" && ok "pulled by the digest that was checked" || bad "pulled by the digest that was checked"
is "its digest is recorded" "$(cat "$work/state/relay.digest")" "$D1"
grep -q "rmi latchkey-relay:bbbbbbbbbbbb" "$work/log" && ok "versions older than the previous one are removed" || bad "versions older than the previous one are removed"
grep -q "rmi latchkey-relay:000000000000" "$work/log" && bad "the previous version is kept for a rollback" || ok "the previous version is kept for a rollback"

run
grep -q "pull -q ghcr.io/tonimelisma/latchkey-relay" "$work/log" && bad "the same image again changes nothing" || ok "the same image again changes nothing"

# An unsigned image (or signed by anyone else) is never used.
echo "$D2" >"$work/latest"
run
is "an unsigned image is not used" "$(cat "$work/running")" "latchkey-relay:aaaaaaaaaaaa"
grep -q "pull -q ghcr.io/tonimelisma/latchkey-relay" "$work/log" && bad "nor pulled" || ok "nor pulled"
grep -q "isn't signed" "$work/out" && ok "and that is logged" || bad "and that is logged"
run
grep -q "isn't signed" "$work/out" && bad "once, not every run" || ok "once, not every run"

# A signed image that doesn't come up healthy: back to the previous version, and skipped.
echo "$D2" >>"$work/signed"
echo unhealthy >"$work/health"
run
is "an unhealthy version is replaced by the previous one" "$(cat "$work/running")" "latchkey-relay:aaaaaaaaaaaa"
is "and remembered as bad" "$(cat "$work/state/relay.bad")" "$D2"
grep -q "not healthy" "$work/out" && ok "with the reason logged" || bad "with the reason logged"
echo healthy >"$work/health"
run
grep -q "compose up" "$work/log" && bad "a bad image isn't tried again" || ok "a bad image isn't tried again"

# Healthy for Docker but not answering at its public address counts as unhealthy.
rm -f "$work/state/relay.bad"
echo no >"$work/answers"
run
is "no answer at the public address: back to the previous version" "$(cat "$work/running")" "latchkey-relay:aaaaaaaaaaaa"
echo yes >"$work/answers"

# No key file on a running relay: not updated blindly.
rm -f "$work/state/relay.bad" "$work/relay/keys/relay/relay.key"
run
is "without the key file nothing changes" "$(cat "$work/running")" "latchkey-relay:aaaaaaaaaaaa"
touch "$work/relay/keys/relay/relay.key"
run
is "with it, the new signed version is used" "$(cat "$work/running")" "latchkey-relay:bbbbbbbbbbbb"

# Not configured yet, or the registry's answer isn't a digest: nothing happens.
rm "$work/relay/relay.env"
echo "sha256:1" >"$work/latest"
run
grep -q "cosign\|pull -q ghcr.io/tonimelisma/latchkey-relay" "$work/log" && bad "an unconfigured server is left alone" || ok "an unconfigured server is left alone"
echo "PUBLIC_URL=https://relay.example.com" >"$work/relay/relay.env"
run
grep -q "cosign\|pull -q ghcr.io/tonimelisma/latchkey-relay" "$work/log" && bad "an odd digest is ignored" || ok "an odd digest is ignored"

# A deploy holding the lock (deploy/deploy.sh: flock <lock> docker compose ...): no run meanwhile.
echo "$D1" >"$work/latest"
rm -f "$work/state/relay.digest"
flock "$work/lock" env W="$work" PATH="$work/bin:$PATH" LATCHKEY_UPDATE_STATE="$work/state" LATCHKEY_RELAY_DIR="$work/relay" \
  LATCHKEY_UPDATE_LOCK="$work/lock" sh "$root/deploy/server/host/update-apps.sh" >/dev/null 2>&1
is "a run while the lock is held changes nothing" "$(cat "$work/running")" "latchkey-relay:bbbbbbbbbbbb"

[ "$fails" -eq 0 ] && echo "update_apps_test: all passed" || { echo "update_apps_test: $fails failed"; exit 1; }
