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

# --- the key file's folder, and the database copy kept across the first start of a version that
# --- encrypts the relay's stored keys (an earlier version can't read them afterwards) ---
cat >"$work/bin/docker" <<'EOF'
#!/bin/sh
echo "docker $*" >>"$DOCKER_LOG"
case "$1" in
inspect)
  [ -z "${NO_CONTAINER-}" ] || exit 1
  printf '/tmp= /data=%s ' "$VOLUME_DIR"
  ;;
esac
exit 0
EOF
cat >"$work/bin/chown" <<'EOF'
#!/bin/sh
echo "chown $*" >>"$DOCKER_LOG"
EOF
chmod +x "$work/bin/"*
on_server() { # runs a deploy function against folders in $work instead of the server
  (
    PATH="$work/bin:$PATH"
    DOCKER_LOG="$work/docker.log" VOLUME_DIR="$work/vol"
    export DOCKER_LOG VOLUME_DIR NO_CONTAINER
    REMOTE_DIR="$work/srv"
    ssh_vm() { sh -c "$1"; }
    "$@"
  )
}
mode() { ls -ld "$1" | cut -c1-10; }
NO_CONTAINER=''
: >"$work/docker.log"
mkdir "$work/srv" "$work/vol"
expect 0 "key folder is prepared" on_server prepare_key_dir
[ "$(mode "$work/srv/keys")" = drwx------ ] && ok "outer key folder is for root only" || bad "outer key folder is for root only"
[ "$(mode "$work/srv/keys/relay")" = drwx------ ] && ok "inner key folder is for one user only" || bad "inner key folder is for one user only"
grep -q "chown root:root $work/srv/keys\$" "$work/docker.log" && ok "outer key folder belongs to root" || bad "outer key folder belongs to root"
grep -q "chown 65532:65532 $work/srv/keys/relay\$" "$work/docker.log" && ok "inner key folder belongs to the container's user" || bad "inner key folder belongs to the container's user"
expect 0 "preparing the key folder again changes nothing" on_server prepare_key_dir

[ "$(on_server key_file_state)" = absent ] && ok "no key file yet is reported" || bad "no key file yet is reported"
printf 'plain-db' >"$work/vol/relay.db"
printf 'plain-wal' >"$work/vol/relay.db-wal"
: >"$work/docker.log"
expect 0 "database is copied before the first start" on_server save_database
grep -q 'docker stop' "$work/docker.log" && ok "relay is stopped before the copy" || bad "relay is stopped before the copy"
[ "$(cat "$work/srv/db-before-keys/relay.db" 2>/dev/null)" = plain-db ] && ok "database file is in the copy" || bad "database file is in the copy"
[ "$(cat "$work/srv/db-before-keys/relay.db-wal" 2>/dev/null)" = plain-wal ] && ok "its write-ahead log is in the copy" || bad "its write-ahead log is in the copy"
[ "$(mode "$work/srv/db-before-keys")" = drwx------ ] && ok "the copy is for root only" || bad "the copy is for root only"

# The new version started, made its key file and converted the database; then it has to go.
printf 'sealed-db' >"$work/vol/relay.db"
rm -f "$work/vol/relay.db-wal"
printf 'sealed-shm' >"$work/vol/relay.db-shm"
printf 'key' >"$work/srv/keys/relay/relay.key"
[ "$(on_server key_file_state)" = present ] && ok "an existing key file is reported" || bad "an existing key file is reported"
expect 0 "database copy is put back" on_server restore_database
[ "$(cat "$work/vol/relay.db")" = plain-db ] && ok "the database is the one from before" || bad "the database is the one from before"
[ "$(cat "$work/vol/relay.db-wal" 2>/dev/null)" = plain-wal ] && ok "with its write-ahead log" || bad "with its write-ahead log"
[ ! -e "$work/vol/relay.db-shm" ] && ok "the newer version's leftovers are gone" || bad "the newer version's leftovers are gone"
[ ! -e "$work/srv/keys/relay/relay.key" ] && ok "the failed version's key file is gone" || bad "the failed version's key file is gone"
[ ! -e "$work/srv/db-before-keys" ] && ok "no copy with unencrypted keys is left" || bad "no copy with unencrypted keys is left"
expect 1 "nothing to put back fails" on_server restore_database

expect 0 "database is copied again" on_server save_database
expect 0 "the copy is deleted after a healthy start" on_server discard_saved_database
[ ! -e "$work/srv/db-before-keys" ] && ok "no copy is left after a healthy start" || bad "no copy is left after a healthy start"
NO_CONTAINER=1
: >"$work/docker.log"
expect 1 "no running relay to copy from fails" on_server save_database
grep -q 'docker stop' "$work/docker.log" && bad "nothing is stopped when the copy can't be made" || ok "nothing is stopped when the copy can't be made"
[ ! -e "$work/srv/db-before-keys" ] && ok "a failed copy leaves nothing" || bad "a failed copy leaves nothing"
NO_CONTAINER=''

# A rollback across that first start puts the database back before the previous version starts.
run_keys_rollback() { # <restore result: 0 or 1>
  : >"$work/ssh.log"
  (
    ssh_vm() { printf '%s\n' "$1" >>"$work/ssh.log"; }
    probe() { [ -n "$(grep 'compose up' "$work/ssh.log")" ]; }
    DB_SAVED=1
    eval "restore_database() { echo restore >>\"$work/ssh.log\"; return $1; }"
    roll_back relay.example.com newtag oldtag 2
  )
}
expect 1 "rollback across the first start fails the deploy" run_keys_rollback 0
[ "$(grep -n '^restore$' "$work/ssh.log" | cut -d: -f1)" -lt "$(grep -n 'compose up' "$work/ssh.log" | cut -d: -f1)" ] 2>/dev/null &&
  ok "database is put back before the previous version starts" || bad "database is put back before the previous version starts"
expect 1 "rollback whose database can't be put back fails" run_keys_rollback 1
grep -q 'compose up' "$work/ssh.log" && bad "previous version isn't started on a database it can't read" || ok "previous version isn't started on a database it can't read"
grep -q 'stays stopped' "$work/out" && ok "that the relay is down is said" || bad "that the relay is down is said"
: >"$work/ssh.log"
(
  ssh_vm() { printf '%s\n' "$1" >>"$work/ssh.log"; }
  probe() { true; }
  restore_database() { echo restore >>"$work/ssh.log"; }
  roll_back relay.example.com newtag oldtag 2
) >/dev/null 2>&1
grep -q '^restore$' "$work/ssh.log" && bad "ordinary rollback leaves the database alone" || ok "ordinary rollback leaves the database alone"
grep -q 'compose up' "$work/ssh.log" && ok "ordinary rollback still starts the previous version" || bad "ordinary rollback still starts the previous version"

# --- the operator's details for the terms and the privacy policy (FR-193): free text from .env
# --- that must reach the relay exactly, through the server's relay.env and docker compose ---
NAME_OK='Sample O. Person-Example'
LAW_OK='California, USA'
PROV_OK='Google Cloud (hosting), Resend (email delivery), Cloudflare (DNS)'
expect 0 "a person's name accepted" check_text OPERATOR_NAME "$NAME_OK" 100
expect 0 "a place with a comma accepted" check_text OPERATOR_LAW "$LAW_OK" 100
expect 0 "providers with commas and parentheses accepted" check_text OPERATOR_PROVIDERS "$PROV_OK" 300
expect 0 "accented letters accepted" check_text OPERATOR_NAME "Zoë Müller" 100
expect 0 "a hash sign accepted (it is no comment inside quotes)" check_text OPERATOR_PROVIDERS "Example #1 Hosting" 300
expect 1 "empty text refused" check_text OPERATOR_NAME "" 100
expect 1 "single quote refused" check_text OPERATOR_NAME "O'Brien" 100
expect 1 "double quote refused" check_text OPERATOR_NAME 'Sam "the" Op' 100
expect 1 "backslash refused" check_text OPERATOR_NAME 'a\b' 100
expect 1 "dollar sign refused" check_text OPERATOR_PROVIDERS 'Cloud ${SMTP_PASSWORD}' 300
expect 1 "backtick refused" check_text OPERATOR_PROVIDERS 'Cloud `id`' 300
expect 1 "line break refused (it would add a setting)" check_text OPERATOR_LAW "California
SMTP_PASSWORD=x" 100
expect 1 "tab refused" check_text OPERATOR_LAW "California	USA" 100
expect 1 "leading space refused" check_text OPERATOR_LAW " California" 100
expect 1 "trailing space refused" check_text OPERATOR_LAW "California " 100
expect 1 "too long refused" check_text OPERATOR_NAME "$(printf '%0101d' 0)" 100
(check_text OPERATOR_NAME "Se'cret Name" 100 >"$work/out" 2>&1)
grep -q "Se'cret" "$work/out" && bad "text refusal doesn't echo the value" || ok "text refusal doesn't echo the value"
grep -q OPERATOR_NAME "$work/out" && ok "text refusal names the variable" || bad "text refusal names the variable"

expect 0 "contact address accepted" check_contact "relay.owner+abuse@example-mail.org"
expect 1 "contact with a name refused" check_contact "Sample <owner@example.org>"
expect 1 "contact without a domain refused" check_contact "owner@"
expect 1 "contact without a dot in the domain refused" check_contact "owner@localhost"
expect 1 "two addresses refused" check_contact "a@example.org,b@example.org"
expect 1 "two at signs refused" check_contact "a@b@example.org"
expect 1 "contact with a space refused" check_contact "owner @example.org"
expect 1 "empty contact refused" check_contact ""
expect 0 "backup days accepted" check_days 14
expect 1 "zero days refused" check_days 0
expect 1 "days with text refused" check_days "14 days"
expect 1 "negative days refused" check_days -3
expect 1 "absurd days refused" check_days 99999
expect 1 "empty days refused" check_days ""

expect 0 "no operator settings at all is fine" check_operator "" "" "" "" ""
expect 0 "name and contact alone are fine" check_operator "$NAME_OK" owner@example.org "" "" ""
expect 0 "all five accepted" check_operator "$NAME_OK" owner@example.org "$LAW_OK" "$PROV_OK" 14
expect 1 "name without contact refused" check_operator "$NAME_OK" "" "" "" ""
expect 1 "contact without name refused" check_operator "" owner@example.org "" "" ""
expect 1 "a bad optional value refused" check_operator "$NAME_OK" owner@example.org 'Cali"fornia' "" ""
expect 1 "bad backup days refused" check_operator "$NAME_OK" owner@example.org "" "" soon
expect 0 "law, providers and days without a name are passed along (the relay ignores them)" check_operator "" "" "$LAW_OK" "" 14

# .env is read as shell: the values are written there in single quotes.
cat >"$work/env-operator" <<'EOF'
OPERATOR_NAME='Sample O. Person-Example'
OPERATOR_CONTACT=owner@example.org
OPERATOR_LAW='California, USA'
OPERATOR_PROVIDERS='Google Cloud (hosting), Resend (email delivery), Cloudflare (DNS)'
BACKUP_DAYS=14
EOF
got=$(
  load_env "$work/env-operator"
  printf '%s|%s|%s|%s|%s' "$OPERATOR_NAME" "$OPERATOR_CONTACT" "$OPERATOR_LAW" "$OPERATOR_PROVIDERS" "$BACKUP_DAYS"
)
[ "$got" = "$NAME_OK|owner@example.org|$LAW_OK|$PROV_OK|14" ] && ok ".env values with spaces, commas and parentheses are read whole" || bad ".env values with spaces, commas and parentheses are read whole"

# The lines for the server's relay.env: only the settings that are set, each value in single quotes.
lines=$(operator_env_lines "$NAME_OK" owner@example.org "$LAW_OK" "$PROV_OK" 14)
want="OPERATOR_NAME='$NAME_OK'
OPERATOR_CONTACT='owner@example.org'
OPERATOR_LAW='$LAW_OK'
OPERATOR_PROVIDERS='$PROV_OK'
BACKUP_DAYS='14'"
[ "$lines" = "$want" ] && ok "relay.env lines are the settings in single quotes" || { bad "relay.env lines are the settings in single quotes"; printf '%s\n' "$lines" | sed 's/^/     /'; }
[ -z "$(operator_env_lines "" "" "" "" "")" ] && ok "no lines when nothing is set" || bad "no lines when nothing is set"
[ "$(operator_env_lines "$NAME_OK" owner@example.org "" "" "")" = "OPERATOR_NAME='$NAME_OK'
OPERATOR_CONTACT='owner@example.org'" ] && ok "unset settings get no line" || bad "unset settings get no line"

# What the relay receives: docker compose reads relay.env as deploy/server/docker-compose.yml
# names it (env_file). Checked with docker compose itself when it is installed.
if docker compose version >/dev/null 2>&1; then
  mkdir -p "$work/compose"
  {
    printf '%s\n' "PUBLIC_URL=https://relay.example.com" "SMTP_FROM=Latchkey <no-reply@relay.example.com>" "SMTP_PASSWORD=re_test_key"
    operator_env_lines "$NAME_OK" owner@example.org "$LAW_OK" "Example #1 (hosting), Resend (email delivery), Cloudflare (DNS)" 14
  } >"$work/compose/relay.env"
  cat >"$work/compose/docker-compose.yml" <<'EOF'
services:
  relay:
    image: example
    env_file: relay.env
EOF
  if (cd "$work/compose" && SMTP_PASSWORD=from-the-shell docker compose config --format json) >"$work/compose/config.json" 2>"$work/out"; then
    seen=$(python3 -c '
import json, sys
e = json.load(open(sys.argv[1]))["services"]["relay"]["environment"]
print("|".join(e.get(k, "<missing>") for k in ("OPERATOR_NAME", "OPERATOR_CONTACT", "OPERATOR_LAW", "OPERATOR_PROVIDERS", "BACKUP_DAYS", "SMTP_FROM")))
' "$work/compose/config.json")
    [ "$seen" = "$NAME_OK|owner@example.org|$LAW_OK|Example #1 (hosting), Resend (email delivery), Cloudflare (DNS)|14|Latchkey <no-reply@relay.example.com>" ] &&
      ok "docker compose hands the relay exactly the text" || { bad "docker compose hands the relay exactly the text"; echo "     $seen"; }
  else
    bad "docker compose reads the sample relay.env"
    sed 's/^/     /' "$work/out"
  fi
else
  echo "skip docker compose is not installed: what it makes of relay.env is not checked here"
fi

# The compose file hands the settings file to the relay.
grep -q '^    env_file: relay.env$' "$root/deploy/server/docker-compose.yml" && ok "compose file reads relay.env" || bad "compose file reads relay.env"
# deploy.sh checks the operator settings and writes their lines.
grep -q 'check_operator ' "$root/deploy/deploy.sh" && grep -q 'operator_env_lines ' "$root/deploy/deploy.sh" &&
  ok "deploy.sh checks and writes the operator settings" || bad "deploy.sh checks and writes the operator settings"

[ "$fails" = 0 ] && echo "all passed" || echo "$fails failed"
[ "$fails" = 0 ]
