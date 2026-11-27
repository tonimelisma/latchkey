#!/bin/sh
# Tests for scripts/cloud-secrets.sh with a stand-in curl (first on the PATH) that plays Entra's
# token endpoint and the two Key Vaults: what reaches CLAUDE_ENV_FILE, that it reads back as the
# same values in a shell, that no value or token is printed or put in curl's arguments, and that
# a failure names only the secret and its HTTP status.
# Run: scripts/tests/cloud_secrets_test.sh (or `make -C relay script-tests`).
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# Values with what a shell would trip on: quotes, $, backslash, spaces.
KEY="c2VjcmV0LWtleQ=="
TOKEN="tok 'quoted' \$HOME \\back \"dq\""
CLIENT_SECRET="cs~secret.value"
VAULT_TOKEN="vault-access-token-xyz"

mkdir -p "$work/bin"
cat >"$work/bin/curl" <<'EOF'
#!/bin/sh
# Stand-in curl: logs its arguments, answers by URL with $CURL_<what> status (default 200).
printf '%s\n' "$*" >>"$STUB_DIR/args"
out="" url="" auth="" data=""
while [ $# -gt 0 ]; do
  case "$1" in
  -o) out=$2; shift ;;
  -H) auth=$(cat "${2#@}"); shift ;;
  --data-urlencode) case "$2" in client_secret@*) data=$(cat "${2#client_secret@}") ;; esac; shift ;;
  -w | -X | --retry | --max-time) shift ;;
  -*) ;;
  *) url=$1 ;;
  esac
  shift
done
case "$url" in
https://login.microsoftonline.com/bd0d0de6-1ba6-42c2-84c6-8e447f1ef6ea/oauth2/v2.0/token)
  code=${CURL_TOKEN:-200}
  [ "$data" = "$WANT_CLIENT_SECRET" ] || code=401
  jq -n --arg t "$WANT_VAULT_TOKEN" '{access_token: $t}' >"$out" ;;
https://kv-melisma-release.vault.azure.net/secrets/latchkey-reports-private-key\?api-version=7.4)
  code=${CURL_KEY:-200}; jq -n --arg v "$WANT_KEY" '{value: $v}' >"$out" ;;
https://kv-melisma-dev.vault.azure.net/secrets/latchkey-intake-developer-token\?api-version=7.4)
  code=${CURL_INTAKE:-200}; jq -n --arg v "$WANT_TOKEN" '{value: $v}' >"$out" ;;
*) code=404; echo '{}' >"$out" ;;
esac
case "$url" in *vault.azure.net*) [ "$auth" = "Authorization: Bearer $WANT_VAULT_TOKEN" ] || code=401 ;; esac
printf '%s' "$code"
EOF
chmod +x "$work/bin/curl"

# run [VAR=value...]: runs the script; output in $out, the env file in $envf.
run() {
  rm -f "$work/args"
  envf="$work/env"
  : >"$envf"
  out=$(env PATH="$work/bin:$PATH" STUB_DIR="$work" CLAUDE_ENV_FILE="$envf" \
    WANT_KEY="$KEY" WANT_TOKEN="$TOKEN" WANT_CLIENT_SECRET="$CLIENT_SECRET" WANT_VAULT_TOKEN="$VAULT_TOKEN" \
    MELISMA_SECRETS_CLIENT_SECRET="$CLIENT_SECRET" "$@" "$root/scripts/cloud-secrets.sh" 2>&1)
}
# secret-free: nothing secret in the output or curl's arguments.
secret_free() {
  for v in "$KEY" "$TOKEN" "$CLIENT_SECRET" "$VAULT_TOKEN"; do
    printf '%s' "$out" | grep -qF -- "$v" && return 1
    [ -f "$work/args" ] && grep -qF -- "$v" "$work/args" && return 1
  done
  return 0
}
# read back: the env file sourced in a clean shell gives the same values.
readback() { env -i sh -c '. "$1"; eval "printf %s \"\$$2\""' sh "$envf" "$1"; }

run
check "both secrets are written" '[ "$(grep -c "^export " "$envf")" = 2 ]'
check "the reports key reads back unchanged" '[ "$(readback LATCHKEY_REPORTS_KEY)" = "$KEY" ]'
check "the intake token reads back unchanged, quotes and all" '[ "$(readback LATCHKEY_INTAKE_TOKEN)" = "$TOKEN" ]'
check "it says what it fetched" 'printf "%s" "$out" | grep -qx "cloud secrets: LATCHKEY_REPORTS_KEY, LATCHKEY_INTAKE_TOKEN from Azure Key Vault"'
check "no value or token in the output or curl's arguments" secret_free

run CURL_INTAKE=403
check "one refused: the other is still written" '[ "$(readback LATCHKEY_REPORTS_KEY)" = "$KEY" ] && ! grep -q LATCHKEY_INTAKE_TOKEN "$envf"'
check "one refused: named with its HTTP status" 'printf "%s" "$out" | grep -qF "not fetched: LATCHKEY_INTAKE_TOKEN (HTTP 403)"'
check "one refused: nothing secret printed" secret_free

run CURL_TOKEN=401
check "no vault token: nothing written" '[ ! -s "$envf" ]'
check "no vault token: the status and both names" 'printf "%s" "$out" | grep -qF "couldn'"'"'t get a Key Vault token (HTTP 401); not fetched: LATCHKEY_REPORTS_KEY LATCHKEY_INTAKE_TOKEN"'
check "no vault token: nothing secret printed" secret_free

run WANT_KEY=
check "an empty value is not written, and says so" '! grep -q LATCHKEY_REPORTS_KEY "$envf" && printf "%s" "$out" | grep -qF "LATCHKEY_REPORTS_KEY (HTTP 200, empty)"'

run MELISMA_SECRETS_CLIENT_SECRET=
check "without the client secret: nothing runs, nothing printed" '[ -z "$out" ] && [ ! -f "$work/args" ] && [ ! -s "$envf" ]'

out=$(env PATH="$work/bin:$PATH" STUB_DIR="$work" MELISMA_SECRETS_CLIENT_SECRET=x CLAUDE_ENV_FILE= "$root/scripts/cloud-secrets.sh" 2>&1)
check "without CLAUDE_ENV_FILE: says so" 'printf "%s" "$out" | grep -q "CLAUDE_ENV_FILE isn"'

[ "$fails" = 0 ] && echo "cloud_secrets_test: all passed" || { echo "cloud_secrets_test: $fails failed"; exit 1; }
