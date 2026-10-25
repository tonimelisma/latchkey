#!/bin/sh
# Functions of deploy/deploy.sh, kept apart so deploy/tests/lib_test.sh can run them without the
# server. Sourced, not run. Callers define ssh_vm (runs one command string on the VM).

# Where the relay's files live on the VM.
REMOTE_DIR=/opt/latchkey

# check_host NAME VALUE: values that end up inside command strings, sed and awk programs, URLs and
# remote commands (host names, the DNS zone, the VM, project and cloud zone names) may hold only
# lowercase letters, digits, dots and hyphens, and must start with a letter or digit so none can
# be read as an option. The value itself is never printed.
check_host() {
  case $2 in
    '' | [!a-z0-9]* | *[!a-z0-9.-]*)
      echo "FAIL: $1 in .env must be non-empty and hold only lowercase letters, digits, dots and hyphens" >&2
      return 1
      ;;
  esac
}

# check_emails VALUE: ALLOWED_EMAILS is written as one line of the server's settings file.
check_emails() {
  case $1 in
    '' | *[!A-Za-z0-9@._+,-]*)
      echo "FAIL: ALLOWED_EMAILS in .env must be addresses separated by commas, with no spaces or quotes" >&2
      return 1
      ;;
  esac
}

# check_secret NAME VALUE: a key is one word; anything else could add lines to the settings file.
check_secret() {
  case $2 in
    '' | *[!A-Za-z0-9_.~+/=-]*)
      echo "FAIL: $1 in .env is empty or holds characters a key never has (spaces, quotes, line breaks)" >&2
      return 1
      ;;
  esac
}

# --- The operator's details for the relay's terms and privacy policy (FR-193) ---
# OPERATOR_NAME, OPERATOR_LAW and OPERATOR_PROVIDERS are free text ("California, USA",
# "Google Cloud (hosting), Resend (email delivery)"). In .env, which is read as shell, they are
# written in single quotes. They travel into the server's relay.env, which docker compose reads
# (env_file): operator_env_lines writes each value in single quotes there too, the one form
# compose takes literally (no ${...} substitution, no escapes, "#" is no comment). So a value may
# hold anything printable on one line except what could end the quoting or mean something to a
# shell: quotes, backslashes, dollar signs, backticks.

# check_text NAME VALUE MAXLENGTH. The value itself is never printed.
check_text() {
  _bad=''
  case $2 in
    '') _bad='is empty' ;;
    *\'* | *\"* | *\\* | *\$* | *\`*) _bad='holds a quote, a backslash, a dollar sign or a backtick' ;;
    ' '* | *' ') _bad='starts or ends with a space' ;;
  esac
  # Control characters (line breaks, tabs, escapes): a line break would add a setting of its own.
  if [ -z "$_bad" ] && [ "$(printf '%s' "$2" | LC_ALL=C tr -d '[:cntrl:]')" != "$2" ]; then
    _bad='holds a line break, a tab or another control character'
  fi
  if [ -z "$_bad" ] && [ "${#2}" -gt "$3" ]; then
    _bad="is longer than $3 characters"
  fi
  if [ -n "$_bad" ]; then
    echo "FAIL: $1 in .env $_bad. Write plain text on one line, in single quotes." >&2
    return 1
  fi
}

# check_contact VALUE: OPERATOR_CONTACT is one plain email address.
check_contact() {
  case $1 in
    '' | *[!A-Za-z0-9@._%+-]* | *@*@* | @* | *@ | *@.* | *.) _ok=0 ;;
    ?*@?*.?*) _ok=1 ;;
    *) _ok=0 ;;
  esac
  if [ "$_ok" = 0 ]; then
    echo "FAIL: OPERATOR_CONTACT in .env must be one email address, without a name" >&2
    return 1
  fi
}

# check_days VALUE: BACKUP_DAYS is a whole number of days, 1 to 9999.
check_days() {
  case $1 in
    '' | *[!0-9]* | 0* | ?????*)
      echo "FAIL: BACKUP_DAYS in .env must be a number of days, such as 14" >&2
      return 1
      ;;
  esac
}

# check_operator NAME CONTACT LAW PROVIDERS BACKUP_DAYS: all optional; name and contact come
# together (the relay refuses to start with only one, so the deploy refuses first).
check_operator() {
  if { [ -n "$1" ] && [ -z "$2" ]; } || { [ -z "$1" ] && [ -n "$2" ]; }; then
    echo "FAIL: OPERATOR_NAME and OPERATOR_CONTACT in .env must be set together, or neither" >&2
    return 1
  fi
  [ -z "$1" ] || check_text OPERATOR_NAME "$1" 100 || return 1
  [ -z "$2" ] || check_contact "$2" || return 1
  [ -z "$3" ] || check_text OPERATOR_LAW "$3" 100 || return 1
  [ -z "$4" ] || check_text OPERATOR_PROVIDERS "$4" 300 || return 1
  [ -z "$5" ] || check_days "$5" || return 1
}

# operator_env_lines NAME CONTACT LAW PROVIDERS BACKUP_DAYS: the lines for relay.env, one per
# setting that is set, each value in single quotes. Call check_operator first: a value with a
# single quote in it would break out of the quoting.
operator_env_lines() {
  [ -z "$1" ] || printf "OPERATOR_NAME='%s'\n" "$1"
  [ -z "$2" ] || printf "OPERATOR_CONTACT='%s'\n" "$2"
  [ -z "$3" ] || printf "OPERATOR_LAW='%s'\n" "$3"
  [ -z "$4" ] || printf "OPERATOR_PROVIDERS='%s'\n" "$4"
  [ -z "$5" ] || printf "BACKUP_DAYS='%s'\n" "$5"
}

# check_ip VALUE: the VM's public IPv4 address as Google Cloud reports it.
check_ip() {
  case $1 in
    '' | *[!0-9.]*)
      echo "FAIL: could not read the VM's public address" >&2
      return 1
      ;;
  esac
}

# check_tag VALUE: an image tag made from a commit hash.
check_tag() {
  case $1 in
    '' | *[!0-9a-f]*)
      echo "FAIL: unexpected image tag" >&2
      return 1
      ;;
  esac
}

# load_env FILE: reads the settings as plain shell variables. Nothing is exported, so the tools
# the deploy runs (scanners, docker, gcloud, curl) don't inherit the keys; each key is handed
# only to the one command that needs it.
load_env() {
  # shellcheck disable=SC1090
  . "$1"
  for _name in $(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}\([A-Za-z_][A-Za-z0-9_]*\)=.*/\2/p' "$1"); do
    eval "_value=\${$_name-}"
    unset "$_name" # drops the export mark, also one inherited from the caller's environment
    eval "$_name=\$_value"
  done
  unset _name _value
}

# require_deployable DIR: only what is on GitHub's main is deployed, so the running relay always
# matches a commit (the image is tagged with it).
require_deployable() {
  if [ -n "$(git -C "$1" status --porcelain)" ]; then
    echo "FAIL: this checkout has uncommitted or untracked files; the deploy would ship them under the last commit's name." >&2
    echo "      Commit them (or remove them), merge into main and push, then deploy again." >&2
    return 1
  fi
  if ! git -C "$1" fetch --quiet origin main; then
    echo "FAIL: couldn't reach origin to compare with main." >&2
    return 1
  fi
  if [ "$(git -C "$1" rev-parse HEAD)" != "$(git -C "$1" rev-parse refs/remotes/origin/main)" ]; then
    echo "FAIL: this checkout is not at origin/main; only main is deployed." >&2
    echo "      Rebase on origin/main and push (git fetch origin && git rebase origin/main && git push origin HEAD:main), then deploy again." >&2
    return 1
  fi
}

# upload_image TAG TMPDIR: copies the image latchkey-relay:TAG to the VM and loads it there. Each
# stage is its own command, so a failure of any of them stops the deploy (a pipeline would report
# only its last stage). The VM checks the upload's SHA-256 before loading it; the upload lives in
# a root-only folder that is removed whatever happens.
upload_image() {
  docker save -o "$2/image.tar" "latchkey-relay:$1" || return 1
  gzip -f "$2/image.tar" || return 1
  _sum=$(shasum -a 256 "$2/image.tar.gz") || return 1
  _sum=${_sum%% *}
  case $_sum in '' | *[!0-9a-f]*) echo "FAIL: could not checksum the image" >&2; return 1 ;; esac
  ssh_vm "sudo sh -euc '
install -d -m 755 $REMOTE_DIR
d=\$(mktemp -d $REMOTE_DIR/.upload.XXXXXX)
trap \"rm -rf \$d\" EXIT
cat > \$d/image.tar.gz
echo \"$_sum  \$d/image.tar.gz\" | sha256sum -c - >/dev/null
docker load -q -i \$d/image.tar.gz >/dev/null
docker image inspect latchkey-relay:$1 >/dev/null
'" <"$2/image.tar.gz" || { echo "FAIL: the image did not arrive intact on the server" >&2; return 1; }
  rm -f "$2/image.tar.gz"
}

# caddyfile_with_block HOST SNIPPET_FILE: prints the Caddyfile on stdin with HOST's site block
# replaced by the snippet (or added when missing). The block is the lines between the snippet's
# BEGIN and END markers, or, as written by earlier deploys, from the line "HOST {" to the next
# line that is just "}".
caddyfile_with_block() {
  awk -v start="$1 {" '
    skip == 0 && $0 == "# BEGIN latchkey relay (written by deploy/deploy.sh)" { skip = 1; next }
    skip == 1 { if ($0 == "# END latchkey relay") skip = 0; next }
    skip == 0 && $0 == start { skip = 2; next }
    skip == 2 { if ($0 == "}") skip = 0; next }
    { print }' || return 1
  cat "$2"
}

# install_caddyfile FILE: writes FILE over the server's Caddyfile in place (it may be mounted into
# the Caddy container as a single file, which a rename would detach), has Caddy check it, and puts
# the previous one back if Caddy refuses it. The caller reloads Caddy.
CADDYFILE=/opt/reverse-proxy/Caddyfile
install_caddyfile() {
  # shellcheck disable=SC2016 # the $ signs are for the VM's shell
  ssh_vm 'sudo sh -euc "
cf='"$CADDYFILE"'
cp -p \$cf \$cf.before-latchkey-deploy
cat > \$cf
if ! out=\$(docker exec caddy caddy validate --config /etc/caddy/Caddyfile 2>&1); then
  printf \"%s\n\" \"\$out\" | tail -5
  cat \$cf.before-latchkey-deploy > \$cf
  echo \"FAIL: Caddy refused the new configuration; the previous Caddyfile is back in place\"
  exit 1
fi
"' <"$1"
}

# probe HOST: the relay answers, and says it is the relay for this host.
probe() {
  curl -fsS --max-time 10 "https://$1/healthz" >/dev/null 2>&1 || return 1
  _meta=$(curl -fsS --max-time 10 "https://$1/.well-known/oauth-protected-resource/mcp" 2>/dev/null) || return 1
  printf '%s' "$_meta" | grep -qF "\"resource\":\"https://$1/mcp\""
}

# wait_healthy HOST TRIES: probes every two seconds until it passes.
wait_healthy() {
  _i=0
  until probe "$1"; do
    _i=$((_i + 1))
    [ "$_i" -ge "$2" ] && return 1
    sleep "${HEALTH_SLEEP:-2}"
  done
}

# finish_or_roll_back HOST NEW_TAG PREVIOUS_TAG [TRIES [ROLLBACK_TRIES]]: waits for the new relay;
# if it doesn't come up, rolls back and fails.
finish_or_roll_back() {
  wait_healthy "$1" "${4:-60}" && return 0
  echo "FAIL: https://$1 did not come up with version $2."
  roll_back "$1" "$2" "$3" "${5:-30}"
}

# roll_back HOST NEW_TAG PREVIOUS_TAG [TRIES]: prints the failed relay's logs, puts the previous
# settings files back, starts the previous image (PREVIOUS_TAG, empty on a first deploy), and
# checks that it answers. Always fails, so the deploy does. When this deploy copied the database
# first (DB_SAVED set: the first start of a version that encrypts the stored keys), the copy is
# put back before the previous version starts; if that fails the relay stays stopped, because
# the previous version can't read a converted database.
roll_back() {
  echo "Last log lines of version $2:"
  ssh_vm 'sudo docker logs --tail 50 latchkey-relay 2>&1' || true
  if [ -z "$3" ]; then
    echo "FAIL: no earlier version on the server to go back to; the relay is down."
    return 1
  fi
  echo "• going back to $3"
  if [ -n "${DB_SAVED-}" ]; then
    echo "• putting back the database from before this version"
    if ! restore_database; then
      echo "FAIL: version $2 was not healthy, and the database copy could not be put back. The relay stays stopped."
      echo "      The copy is in $REMOTE_DIR/db-before-keys on the server; version $3 can't read the database as it is now."
      return 1
    fi
  fi
  ssh_vm "set -e
cd $REMOTE_DIR
for f in docker-compose.yml relay.env; do
  if sudo test -f \$f.prev; then sudo cp -p \$f.prev \$f; fi
done
sudo TAG=$3 docker compose up -d --remove-orphans --quiet-pull" || true
  if wait_healthy "$1" "${4:-30}"; then
    echo "FAIL: version $2 was not healthy; rolled back to $3, which is answering again."
  else
    echo "FAIL: version $2 was not healthy, and after going back to $3 the relay is still not answering. It is down."
    ssh_vm 'sudo docker logs --tail 50 latchkey-relay 2>&1' || true
  fi
  return 1
}

# --- The key file that encrypts the relay's stored keys (FR-186) ---
# It lives outside the data volume, so a copy of the database or of the volume alone can't be
# used to forge tokens: in $REMOTE_DIR/keys/relay, mounted into the container at /keys. The
# folder above it is root's alone, so nobody else on the VM can reach the file; the inner folder
# belongs to the container's user (the image's "nonroot"), which creates the file on its first
# start and reads it afterwards.
KEY_OWNER=65532:65532

# prepare_key_dir: makes those two folders. Safe to rerun.
prepare_key_dir() {
  ssh_vm "sudo sh -euc '
install -d -m 700 $REMOTE_DIR/keys
chown root:root $REMOTE_DIR/keys
install -d -m 700 $REMOTE_DIR/keys/relay
chown $KEY_OWNER $REMOTE_DIR/keys/relay
'"
}

# key_file_state: prints "present" or "absent". Anything else (a failed connection) must stop the
# deploy: "absent" decides that the database is copied first and, on a rollback, that the key file
# the failed version made is deleted.
key_file_state() {
  ssh_vm "if sudo test -f $REMOTE_DIR/keys/relay/relay.key; then echo present; else echo absent; fi" | tr -d ' \r\n'
}

# save_database: before the first start of a version that encrypts the stored keys, stops the
# relay and copies its database files into a root-only folder. A version from before can't read
# the database once it is converted, so a rollback needs this copy (restore_database). Fails,
# stopping and changing nothing, when the running relay's database can't be found.
save_database() {
  ssh_vm "sudo sh -euc '
src=
for m in \$(docker inspect --format \"{{range .Mounts}}{{.Destination}}={{.Source}} {{end}}\" latchkey-relay); do
  case \$m in /data=*) src=\${m#/data=} ;; esac
done
test -n \"\$src\"
test -f \"\$src/relay.db\"
d=$REMOTE_DIR/db-before-keys
rm -rf \$d \$d.new
install -d -m 700 \$d.new
docker stop -t 20 latchkey-relay >/dev/null
for f in relay.db relay.db-wal relay.db-shm; do
  if [ -f \"\$src/\$f\" ]; then cp -p \"\$src/\$f\" \$d.new/\$f; fi
done
printf %s \"\$src\" > \$d.new/source
mv \$d.new \$d
'"
}

# restore_database: puts the copy made by save_database back over the database, deletes the key
# file the failed version created (nothing is encrypted with it any more), and deletes the copy.
# The caller starts the previous version afterwards.
restore_database() {
  ssh_vm "sudo sh -euc '
d=$REMOTE_DIR/db-before-keys
test -f \$d/relay.db
src=\$(cat \$d/source)
test -n \"\$src\"
docker stop -t 20 latchkey-relay >/dev/null 2>&1 || true
rm -f \"\$src/relay.db-wal\" \"\$src/relay.db-shm\"
for f in relay.db relay.db-wal relay.db-shm; do
  if [ -f \$d/\$f ]; then cp -p \$d/\$f \"\$src/\$f\"; fi
done
rm -f $REMOTE_DIR/keys/relay/relay.key
rm -rf \$d
'"
}

# discard_saved_database: once the new version answers, the copy (which holds the keys
# unencrypted) is deleted.
discard_saved_database() {
  ssh_vm "sudo rm -rf $REMOTE_DIR/db-before-keys $REMOTE_DIR/db-before-keys.new"
}
