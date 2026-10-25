#!/bin/sh
# Tests for deploy/lib.sh: everything in the deploy that can be checked without the server.
# Run: deploy/tests/lib_test.sh (or `make -C relay script-tests`). Exit code is the result.
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
# expect <0|1> <name> <command...>: the command (run in a subshell) must succeed (0) or fail (1).
expect() {
  want=$1 name=$2
  shift 2
  if ("$@") >"$work/out" 2>&1; then got=0; else got=1; fi
  if [ "$got" = "$want" ]; then ok "$name"; else bad "$name"; sed 's/^/     /' "$work/out"; fi
}

# shellcheck source=deploy/lib.sh
. "$root/deploy/lib.sh"

# --- values that reach command strings ---
expect 0 "host name accepted" check_host DEPLOY_HOST relay.example-1.com
expect 1 "empty host refused" check_host DEPLOY_HOST ""
expect 1 "upper case refused" check_host DEPLOY_HOST Relay.example.com
expect 1 "quote refused" check_host DEPLOY_HOST "a.com'; rm -rf /; '"
expect 1 "slash refused (sed delimiter)" check_host DEPLOY_HOST "a/b"
expect 1 "space refused" check_host DEPLOY_HOST "a b"
expect 1 "newline refused" check_host DEPLOY_HOST "a
b"
expect 1 "leading hyphen refused (option)" check_host DEPLOY_VM "-oProxyCommand=x"
expect 1 "dollar refused" check_host DEPLOY_PROJECT 'a$(id)'
(check_host DEPLOY_HOST 'se"cret' >"$work/out" 2>&1)
if grep -q 'se"cret' "$work/out"; then bad "refusal doesn't echo the value"; else ok "refusal doesn't echo the value"; fi
grep -q DEPLOY_HOST "$work/out" && ok "refusal names the variable" || bad "refusal names the variable"

expect 0 "emails accepted" check_emails "a@example.com,b.c+d@example.org"
expect 1 "emails with a newline refused" check_emails "a@example.com
SMTP_PASSWORD=x"
expect 1 "emails with a space refused" check_emails "a@example.com, b@example.com"
expect 0 "key accepted" check_secret RESEND_API_KEY "re_Abc-123_x"
expect 1 "key with a newline refused" check_secret RESEND_API_KEY "re_abc
X=1"
expect 0 "IPv4 accepted" check_ip 203.0.113.7
expect 1 "empty address refused" check_ip ""
expect 1 "address with text refused" check_ip "203.0.113.7; id"
expect 0 "image tag accepted" check_tag 1a2b3c4
expect 1 "odd image tag refused" check_tag 'x;y'

# --- .env is read without exporting anything ---
cat >"$work/env" <<'EOF'
CLOUDFLARE_API_TOKEN=cf-test-token
export RESEND_API_KEY=re_test_key
RESEND_ADMIN_KEY=re_admin_key
DEPLOY_HOST=relay.example.com
EOF
leak=$(
  export CLOUDFLARE_API_TOKEN=from-parent-environment
  load_env "$work/env"
  [ "$CLOUDFLARE_API_TOKEN" = cf-test-token ] || echo "value not read"
  [ "$RESEND_API_KEY" = re_test_key ] || echo "value not read"
  [ "$DEPLOY_HOST" = relay.example.com ] || echo "value not read"
  env | grep -E 'cf-test-token|re_test_key|re_admin_key|from-parent|relay\.example\.com' | sed 's/=.*//'
)
if [ -z "$leak" ]; then ok ".env values are not exported to child processes"; else bad ".env values are not exported to child processes"; echo "     $leak"; fi

# --- only a clean checkout at origin/main is deployed ---
git init -q --bare "$work/origin.git"
git clone -q "$work/origin.git" "$work/repo" 2>/dev/null
(
  cd "$work/repo" && git checkout -q -b main && echo one >file && git add file &&
    git -c user.name=t -c user.email=t@example.com commit -q -m one && git push -q origin main
) >/dev/null 2>&1
expect 0 "clean checkout at origin/main may deploy" require_deployable "$work/repo"
echo stray >"$work/repo/untracked"
expect 1 "untracked file refuses the deploy" require_deployable "$work/repo"
rm "$work/repo/untracked"
echo two >>"$work/repo/file"
expect 1 "uncommitted change refuses the deploy" require_deployable "$work/repo"
(cd "$work/repo" && git -c user.name=t -c user.email=t@example.com commit -q -am two)
expect 1 "unpushed commit refuses the deploy" require_deployable "$work/repo"
(cd "$work/repo" && git push -q origin main) >/dev/null 2>&1
expect 0 "pushed again: may deploy" require_deployable "$work/repo"
(cd "$work/repo" && git checkout -q HEAD~1) >/dev/null 2>&1
expect 1 "checkout behind origin/main refuses the deploy" require_deployable "$work/repo"

# --- the Caddyfile block is replaced, not appended twice ---
snippet="$work/snippet"
sed "s/{{HOST}}/relay.example.com/g" "$root/deploy/server/Caddyfile.snippet" >"$snippet"
cat >"$work/Caddyfile" <<'EOF'
other.example.com {
	reverse_proxy other:80
}

relay.example.com {
	# Access log (old block, written by an earlier deploy)
	log {
		output file /data/latchkey-access.log {
			roll_size 10MiB
		}
	}
	reverse_proxy latchkey-relay:8080
}
after.example.com {
	respond "hi"
}
EOF
caddyfile_with_block relay.example.com "$snippet" <"$work/Caddyfile" >"$work/Caddyfile.1"
[ "$(grep -cx 'relay.example.com {' "$work/Caddyfile.1")" = 1 ] && ok "old block replaced once" || bad "old block replaced once"
grep -q 'old block' "$work/Caddyfile.1" && bad "old block's contents removed" || ok "old block's contents removed"
grep -q 'resp_headers>Location delete' "$work/Caddyfile.1" && ok "new block has the log filter" || bad "new block has the log filter"
[ "$(grep -c 'other.example.com {\|after.example.com {\|respond "hi"\|reverse_proxy other:80' "$work/Caddyfile.1")" = 4 ] &&
  ok "other sites untouched" || bad "other sites untouched"
caddyfile_with_block relay.example.com "$snippet" <"$work/Caddyfile.1" >"$work/Caddyfile.2"
cmp -s "$work/Caddyfile.1" "$work/Caddyfile.2" && ok "second run changes nothing" || bad "second run changes nothing"

# --- a failed health check brings the previous version back ---
HEALTH_SLEEP=0
run_finish() { # <probe results, one per call, last repeats> <previous tag>
  : >"$work/ssh.log"
  printf '%s\n' "$1" >"$work/probes"
  (
    ssh_vm() { printf '%s\n' "$1" >>"$work/ssh.log"; }
    probe() {
      r=$(head -1 "$work/probes")
      [ "$(wc -l <"$work/probes")" -gt 1 ] && sed 1d "$work/probes" >"$work/probes.n" && mv "$work/probes.n" "$work/probes"
      [ "$r" = up ]
    }
    finish_or_roll_back relay.example.com newtag "$2" 2 2
  )
}
expect 0 "healthy deploy succeeds" run_finish up oldtag
grep -q 'compose up' "$work/ssh.log" && bad "healthy deploy doesn't roll back" || ok "healthy deploy doesn't roll back"
expect 1 "unhealthy deploy fails" run_finish "down
down
up" oldtag
grep -q 'docker logs' "$work/ssh.log" && ok "failed container's logs are printed" || bad "failed container's logs are printed"
grep -q 'TAG=oldtag docker compose up' "$work/ssh.log" && ok "previous version is started again" || bad "previous version is started again"
grep -q 'rolled back to oldtag' "$work/out" && ok "rollback is verified healthy and reported" || bad "rollback is verified healthy and reported"
expect 1 "unhealthy deploy and unhealthy rollback fails" run_finish down oldtag
grep -q 'still not answering' "$work/out" && ok "failed rollback is reported" || bad "failed rollback is reported"
expect 1 "unhealthy first deploy fails" run_finish down ""
grep -q 'compose up' "$work/ssh.log" && bad "first deploy has nothing to roll back to" || ok "first deploy has nothing to roll back to"

# --- the image upload: any failing stage fails the deploy ---
mkdir "$work/bin" "$work/remote"
cat >"$work/bin/sudo" <<'EOF'
#!/bin/sh
exec "$@"
EOF
cat >"$work/bin/docker" <<'EOF'
#!/bin/sh
echo "docker $*" >>"$DOCKER_LOG"
case "$1" in
save) [ -z "${FAIL_SAVE-}" ] || exit 1; printf 'image-bytes' >"$3" ;;
load) [ -z "${FAIL_LOAD-}" ] || exit 1 ;;
esac
exit 0
EOF
command -v sha256sum >/dev/null 2>&1 || cat >"$work/bin/sha256sum" <<'EOF'
#!/bin/sh
exec shasum -a 256 "$@"
EOF
chmod +x "$work/bin/"*
run_upload() {
  (
    PATH="$work/bin:$PATH"
    DOCKER_LOG="$work/docker.log"
    export DOCKER_LOG FAIL_SAVE FAIL_LOAD
    : >"$DOCKER_LOG"
    REMOTE_DIR="$work/remote"
    ssh_vm() { if [ -n "${CORRUPT-}" ]; then echo garbage | sh -c "$1"; else sh -c "$1"; fi; }
    mkdir -p "$work/tmp" && upload_image abc1234 "$work/tmp"
  )
}
FAIL_SAVE='' FAIL_LOAD='' CORRUPT=''
expect 0 "image upload succeeds" run_upload
grep -q 'docker load' "$work/docker.log" && ok "image is loaded on the server" || bad "image is loaded on the server"
[ -z "$(ls -A "$work/remote")" ] && ok "no upload left on the server" || bad "no upload left on the server"
FAIL_SAVE=1
expect 1 "failing docker save fails the deploy" run_upload
grep -q 'docker load' "$work/docker.log" && bad "nothing is loaded after a failed save" || ok "nothing is loaded after a failed save"
FAIL_SAVE='' FAIL_LOAD=1
expect 1 "failing docker load fails the deploy" run_upload
FAIL_LOAD='' CORRUPT=1
expect 1 "upload damaged on the way fails the deploy" run_upload
grep -q 'docker load' "$work/docker.log" && bad "a damaged upload is never loaded" || ok "a damaged upload is never loaded"
[ -z "$(ls -A "$work/remote")" ] && ok "no damaged upload left on the server" || bad "no damaged upload left on the server"

# --- the server's Caddyfile: checked by Caddy, put back if refused ---
run_caddy() {
  (
    PATH="$work/bin:$PATH"
    DOCKER_LOG="$work/docker.log"
    export DOCKER_LOG FAIL_VALIDATE
    CADDYFILE="$work/live/Caddyfile"
    ssh_vm() { sh -c "$1"; }
    install_caddyfile "$work/Caddyfile.1"
  )
}
cat >"$work/bin/docker" <<'EOF'
#!/bin/sh
echo "docker $*" >>"$DOCKER_LOG"
if [ -n "${FAIL_VALIDATE-}" ]; then echo "Error: adapting config: unrecognized directive"; exit 1; fi
exit 0
EOF
mkdir "$work/live"
cp "$work/Caddyfile" "$work/live/Caddyfile"
FAIL_VALIDATE=1
expect 1 "Caddyfile that Caddy refuses fails the deploy" run_caddy
cmp -s "$work/Caddyfile" "$work/live/Caddyfile" && ok "refused Caddyfile: the previous one is back" || bad "refused Caddyfile: the previous one is back"
grep -q 'unrecognized directive' "$work/out" && ok "Caddy's reason is shown" || bad "Caddy's reason is shown"
FAIL_VALIDATE=''
expect 0 "valid Caddyfile is installed" run_caddy
cmp -s "$work/Caddyfile.1" "$work/live/Caddyfile" && ok "new Caddyfile is in place" || bad "new Caddyfile is in place"
cmp -s "$work/Caddyfile" "$work/live/Caddyfile.before-latchkey-deploy" && ok "previous Caddyfile kept as a backup" || bad "previous Caddyfile kept as a backup"

[ "$fails" = 0 ] && echo "all passed" || echo "$fails failed"
[ "$fails" = 0 ]
