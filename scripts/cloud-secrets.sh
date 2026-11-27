#!/bin/sh
# Fetches a cloud session's secrets from Azure Key Vault (managed from the private repository
# tonimelisma/secrets) and hands them to the session's later commands through CLAUDE_ENV_FILE.
# Run by scripts/cloud-setup.sh at session start; does nothing unless
# MELISMA_SECRETS_CLIENT_SECRET is set (the one variable of the shared claude.ai environment, the
# client secret of the Entra app cloud-sessions-reader; docs/cloud-sessions.md).
#
#   LATCHKEY_REPORTS_KEY   kv-melisma-release/latchkey-reports-private-key   (latchkey-reports)
#   LATCHKEY_INTAKE_TOKEN  kv-melisma-dev/latchkey-intake-developer-token    (latchkey-reports)
#
# The reports key is stored as the key file ~/.config/latchkey-reports/developer.key holds it
# (base64, which is what LATCHKEY_REPORTS_KEY takes), so it is passed on unchanged.
# Never prints a value or the vault token, and never puts them in a command's arguments (curl
# reads them from files in a private temporary folder); on failure it names the secret and the
# HTTP status. Prints one line. Tested by scripts/tests/cloud_secrets_test.sh.
set -u
[ -n "${MELISMA_SECRETS_CLIENT_SECRET:-}" ] || exit 0
[ -n "${CLAUDE_ENV_FILE:-}" ] || { echo "cloud secrets: CLAUDE_ENV_FILE isn't set, so no secrets were fetched"; exit 0; }
for t in curl jq; do
  command -v "$t" >/dev/null 2>&1 || { echo "cloud secrets: $t is missing, so no secrets were fetched"; exit 0; }
done

# Not secret: which app, in which tenant.
TENANT=bd0d0de6-1ba6-42c2-84c6-8e447f1ef6ea
CLIENT_ID=5154d2ee-bdf5-49cf-8643-8918b3e8c32c
# NAME vault secret, one per line.
SECRETS='LATCHKEY_REPORTS_KEY kv-melisma-release latchkey-reports-private-key
LATCHKEY_INTAKE_TOKEN kv-melisma-dev latchkey-intake-developer-token'

umask 077
tmp=$(mktemp -d) || { echo "cloud secrets: no temporary folder, so no secrets were fetched"; exit 0; }
trap 'rm -rf "$tmp"' EXIT
printf '%s' "$MELISMA_SECRETS_CLIENT_SECRET" >"$tmp/client-secret"

# status <curl args...>: runs curl with the answer in $tmp/body; prints the HTTP status (000 when
# there was no answer).
status() { curl -sS --retry 2 --max-time 30 -o "$tmp/body" -w '%{http_code}' "$@" 2>/dev/null || true; }

code=$(status -X POST "https://login.microsoftonline.com/$TENANT/oauth2/v2.0/token" \
  --data-urlencode grant_type=client_credentials --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "client_secret@$tmp/client-secret" --data-urlencode scope=https://vault.azure.net/.default)
token=""
[ "$code" = 200 ] && token=$(jq -r '.access_token // empty' "$tmp/body" 2>/dev/null)
rm -f "$tmp/client-secret"
if [ -z "$token" ]; then
  echo "cloud secrets: couldn't get a Key Vault token (HTTP ${code:-000}); not fetched: $(printf '%s\n' "$SECRETS" | cut -d' ' -f1 | paste -sd' ' -)"
  exit 0
fi
printf 'Authorization: Bearer %s\n' "$token" >"$tmp/auth"
unset token

got="" failed=""
while read -r name vault secret; do
  code=$(status -H "@$tmp/auth" "https://$vault.vault.azure.net/secrets/$secret?api-version=7.4")
  value=""
  [ "$code" = 200 ] && value=$(jq -r '.value // empty' "$tmp/body" 2>/dev/null)
  if [ -z "$value" ]; then
    [ "$code" = 200 ] && code="200, empty"
    failed="$failed${failed:+, }$name (HTTP ${code:-000})"
    continue
  fi
  # Single-quoted for the shell that reads the file: each ' becomes '\''.
  printf "export %s='%s'\n" "$name" "$(printf '%s' "$value" | sed "s/'/'\\\\''/g")" >>"$CLAUDE_ENV_FILE"
  got="$got${got:+, }$name"
done <<EOF
$SECRETS
EOF
rm -f "$tmp/auth" "$tmp/body"

if [ -z "$failed" ]; then
  echo "cloud secrets: $got from Azure Key Vault"
else
  echo "cloud secrets: ${got:-nothing} from Azure Key Vault; not fetched: $failed"
fi
