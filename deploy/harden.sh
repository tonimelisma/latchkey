#!/bin/sh
# Locks down the relay's server and its Google Cloud project, and sets up intrusion detection
# with alerts emailed to the owner (Toni, 2026-11-21). Safe to rerun: each step changes only
# what differs. What and why: docs/threat-model.md, "The relay's server".
#
# Runs in the infra workflow (.github/workflows/infra.yml, task "harden"), signed in to Google
# Cloud as the service account latchkey-infra through Workload Identity Federation (no stored key;
# deploy/gcp-wif-setup.sh), or by the owner signed in to gcloud. Either way the identity is
# checked: the owner's own account, or exactly latchkey-infra in this project.
# Reads from the repository's .env (gitignored) when there is one, else from the environment (the
# workflow's secrets), like deploy/deploy.sh:
#   DEPLOY_HOST, DEPLOY_VM, DEPLOY_PROJECT, DEPLOY_ZONE   the relay's host name and its VM
#   ALERT_EMAIL         where alerts go
#   OWNER_ACCOUNT       the owner's Google account; needed when the service account runs this
#                       (signed in as the owner, it is that account)
#   APP_BUCKETS         optional: Cloud Storage buckets the server's other apps back up to
#                       (comma-separated); the server's own account may use only these
# The owner and the two automation identities (latchkey-infra, and hackernews-admin for the app
# that shares the server) are the ones whose IAP use and server sessions are expected: the alert
# "server sign-in by someone else" leaves them out, and the sentinel counts their sessions as the
# owner's (docs/threat-model.md, "The relay's server").
#
# In the cloud project: the VM runs as its own service account that may only write logs and
# metrics (and use APP_BUCKETS), never Google's default one with Editor; Secure Boot; deletion
# protection; SSH only through Google's IAP tunnel, signing in with OS Login (no SSH keys in
# metadata); IAP's access log on; the alerts (deploy/alerts.py).
# On the server (deploy/server/host/setup.sh): unneeded packages and services gone, SSH and the
# kernel tightened, automatic updates with a nightly reboot when needed, Docker's safer settings,
# each app on its own network with Caddy, the old local accounts locked, audit rules and the
# sentinel. Restarting the VM (once, when its account or Secure Boot change, or an update needs
# it) takes about two minutes; the Macs reconnect by themselves.
set -eu
LOCK=$HOME/Library/Caches/net.melisma.latchkey.deploy.lock
if [ -x /usr/bin/lockf ] && [ "${LATCHKEY_DEPLOY_LOCKED:-}" != "$LOCK" ]; then
  LATCHKEY_DEPLOY_LOCKED=$LOCK exec /usr/bin/lockf -t 900 "$LOCK" "$0" "$@"
fi
LC_ALL=C
export LC_ALL
cd "$(dirname "$0")/.."
. deploy/lib.sh
scripts/link-local-files.sh
load_settings ./.env DEPLOY_HOST DEPLOY_VM DEPLOY_PROJECT DEPLOY_ZONE ALERT_EMAIL OWNER_ACCOUNT APP_BUCKETS
: "${DEPLOY_HOST:?missing in .env}" "${DEPLOY_VM:?missing in .env}" "${DEPLOY_PROJECT:?missing in .env}" "${DEPLOY_ZONE:?missing in .env}"
: "${ALERT_EMAIL:?missing in .env (where alerts go)}"
check_host DEPLOY_HOST "$DEPLOY_HOST"
check_host DEPLOY_VM "$DEPLOY_VM"
check_host DEPLOY_PROJECT "$DEPLOY_PROJECT"
check_host DEPLOY_ZONE "$DEPLOY_ZONE"
check_contact "$ALERT_EMAIL" || { echo "FAIL: ALERT_EMAIL in .env must be one email address" >&2; exit 1; }
check_buckets "${APP_BUCKETS-}"
VM=$DEPLOY_VM PROJECT=$DEPLOY_PROJECT ZONE=$DEPLOY_ZONE HOST=$DEPLOY_HOST
SA_NAME=relay-vm
SA=$SA_NAME@$PROJECT.iam.gserviceaccount.com
SCOPES=https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/devstorage.read_write
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' INT TERM HUP
# gc: a gcloud command that must work (its errors are shown); gcv: one whose failure is an answer.
gc() {
  if ! gcloud "$@" --project "$PROJECT" --quiet >"$tmp/gc.out" 2>"$tmp/gc.err"; then
    gcloud_noise <"$tmp/gc.err" >&2
    echo "FAIL: gcloud $1 $2 $3" >&2
    return 1
  fi
  cat "$tmp/gc.out"
}
gcv() { gcloud "$@" --project "$PROJECT" --quiet 2>/dev/null; }
ssh_vm() { vm_ssh "$VM" "$PROJECT" "$ZONE" "$1"; }

INFRA_SA=latchkey-infra@$PROJECT.iam.gserviceaccount.com
HN_SA=hackernews-admin@$PROJECT.iam.gserviceaccount.com
RUNNER=$(gcloud config get account 2>/dev/null || true)
[ -n "$RUNNER" ] || RUNNER=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1)
check_contact "$RUNNER" || { echo "FAIL: gcloud isn't signed in with an email account" >&2; exit 1; }
case $RUNNER in
  *.gserviceaccount.com)
    [ "$RUNNER" = "$INFRA_SA" ] || { echo "FAIL: gcloud is signed in as a service account other than latchkey-infra" >&2; exit 1; }
    OWNER=${OWNER_ACCOUNT-}
    check_contact "$OWNER" || { echo "FAIL: OWNER_ACCOUNT (the owner's Google account) is needed when latchkey-infra runs this" >&2; exit 1; }
    ;;
  *) OWNER=$RUNNER ;;
esac
mask "$OWNER"
gcv projects get-iam-policy "$PROJECT" --format=json >"$tmp/iam.json"
python3 -I deploy/iam.py is-owner "$OWNER" <"$tmp/iam.json" ||
  { echo "FAIL: the owner's account ($OWNER) isn't an owner of the project" >&2; exit 1; }

# Each cloud change below is made only when something differs: every write is an admin action,
# and each one emails the owner ("Latchkey: cloud project changed"), so a rerun stays quiet.
echo "• Google Cloud services for IAP, OS Login and alerts"
enabled=$(gcv services list --enabled --format='value(config.name)')
for api in iap.googleapis.com oslogin.googleapis.com monitoring.googleapis.com logging.googleapis.com; do
  printf '%s\n' "$enabled" | grep -qx "$api" || gc services enable "$api" >/dev/null
done

echo "• SSH through Google's IAP tunnel, with OS Login"
if ! gcv compute firewall-rules describe allow-ssh-iap >/dev/null; then
  gc compute firewall-rules create allow-ssh-iap --network default --direction INGRESS --priority 1000 \
    --source-ranges 35.235.240.0/20 --allow tcp:22 --description "SSH only through Google's IAP tunnel (deploy/harden.sh)" >/dev/null
fi
gcv compute instances describe "$VM" --zone "$ZONE" --format=json >"$tmp/vm.json"
if ! python3 -I deploy/iam.py metadata-ok <"$tmp/vm.json"; then
  gc compute instances add-metadata "$VM" --zone "$ZONE" --metadata enable-oslogin=TRUE,block-project-ssh-keys=TRUE >/dev/null
fi
if gcv compute project-info describe --format='value(commonInstanceMetadata.items[].key)' | tr ';' '\n' | grep -qx ssh-keys; then
  gc compute project-info remove-metadata --keys ssh-keys >/dev/null
  echo "  - SSH keys in the project's metadata removed"
fi
# The OS Login accounts whose sessions are the owner's own (the sentinel stays quiet): the one
# running this (the owner, or latchkey-infra), those already on the server from earlier runs, and
# the two automation service accounts, by their OS Login names (sa_<unique id>; the server
# resolves their numbers when they sign in).
gcv compute os-login describe-profile --format=json >"$tmp/profile.json"
ssh_vm 'sudo cat /etc/latchkey-sentinel.json 2>/dev/null || true' >"$tmp/sentinel-old.json"
set --
for sa in "$INFRA_SA" "$HN_SA"; do
  id=$(gcv iam service-accounts describe "$sa" --format='value(uniqueId)' || true)
  case $id in '' | *[!0-9]*) ;; *) set -- "$@" --user "sa_$id" ;; esac
done
python3 -I deploy/iam.py sentinel-config --existing "$tmp/sentinel-old.json" "$@" <"$tmp/profile.json" >"$tmp/sentinel.json"

echo "• the server"
cp -R deploy/server/host "$tmp/host"
cp "$tmp/sentinel.json" "$tmp/host/sentinel.json"
COPYFILE_DISABLE=1 tar --no-xattrs -czf "$tmp/host.tgz" -C "$tmp/host" .
# shellcheck disable=SC2016 # for the VM's shell
ssh_vm 'sudo sh -euc '"'"'d=$(mktemp -d /root/latchkey-harden.XXXXXX); trap "rm -rf $d" EXIT; tar -xzf - -C $d --no-same-owner; sh $d/setup.sh'"'" \
  <"$tmp/host.tgz" | tee "$tmp/setup.out"
# A new connection proves the SSH settings work; it cancels their 5-minute undo.
ssh_vm 'sudo systemctl stop latchkey-sshd-undo.timer >/dev/null 2>&1; sudo systemctl reset-failed latchkey-sshd-undo >/dev/null 2>&1; true'
ssh_vm 'sudo cmp -s /etc/ssh/sshd_config.d/01-latchkey.conf /dev/stdin' <deploy/server/host/sshd.conf ||
  { echo "FAIL: the server's SSH settings aren't the hardened ones (were they undone?); run deploy/harden.sh again" >&2; exit 1; }
REBOOT=''
[ "$(tail -1 "$tmp/setup.out")" != REBOOT ] || REBOOT=1

echo "• the server's own service account"
if ! gcv iam service-accounts describe "$SA" >/dev/null; then
  gc iam service-accounts create "$SA_NAME" --display-name "Latchkey relay server" \
    --description "The relay's VM: writes logs and metrics only (deploy/harden.sh)" >/dev/null
  sleep 10
fi
for role in roles/logging.logWriter roles/monitoring.metricWriter; do
  python3 -I deploy/iam.py has-role "serviceAccount:$SA" "$role" <"$tmp/iam.json" ||
    gc projects add-iam-policy-binding "$PROJECT" --member "serviceAccount:$SA" --role "$role" --condition=None >/dev/null
done
for bucket in $(printf '%s' "${APP_BUCKETS-}" | tr ',' ' '); do
  gcv storage buckets get-iam-policy "gs://$bucket" --format=json >"$tmp/bucket.json" || : >"$tmp/bucket.json"
  python3 -I deploy/iam.py has-role "serviceAccount:$SA" roles/storage.objectUser <"$tmp/bucket.json" 2>/dev/null ||
    gc storage buckets add-iam-policy-binding "gs://$bucket" --member "serviceAccount:$SA" --role roles/storage.objectUser >/dev/null
done
DEFAULT_SA=$(gcv projects describe "$PROJECT" --format='value(projectNumber)')-compute@developer.gserviceaccount.com
if python3 -I deploy/iam.py has-role "serviceAccount:$DEFAULT_SA" roles/editor <"$tmp/iam.json"; then
  gc projects remove-iam-policy-binding "$PROJECT" --member "serviceAccount:$DEFAULT_SA" --role roles/editor --condition=None >/dev/null
  echo "  - Google's default service account no longer has Editor"
fi

echo "• IAP's access log (who reached the server)"
gcv projects get-iam-policy "$PROJECT" --format=json >"$tmp/iam.json"
if python3 -I deploy/iam.py add-iap-audit <"$tmp/iam.json" >"$tmp/iam-new.json"; then
  gc projects set-iam-policy "$PROJECT" "$tmp/iam-new.json" >/dev/null
  echo "  - turned on"
fi

echo "• the VM: its own account, Secure Boot, deletion protection"
gcv compute instances describe "$VM" --zone "$ZONE" --format=json >"$tmp/vm.json"
if ! python3 -I deploy/iam.py vm-ok "$SA" "$SCOPES" <"$tmp/vm.json"; then
  # A stopped VM keeps its public address only when the address is reserved; otherwise the
  # relay's DNS record would point at nothing.
  IP=$(gcv compute instances describe "$VM" --zone "$ZONE" --format='value(networkInterfaces[0].accessConfigs[0].natIP)')
  check_ip "$IP"
  mask "$IP"
  if [ -z "$(gcv compute addresses list --filter="address=$IP" --format='value(name)')" ]; then
    echo "FAIL: the VM's address $IP isn't reserved, so stopping it would change it. Reserve it first:" >&2
    echo "      gcloud compute addresses create $VM-ip --addresses $IP --region ${ZONE%-*} --project $PROJECT" >&2
    exit 1
  fi
  echo "  - stopping the VM to change its account and turn on Secure Boot (about two minutes)"
  gc compute instances stop "$VM" --zone "$ZONE" >/dev/null
  gc compute instances set-service-account "$VM" --zone "$ZONE" --service-account "$SA" --scopes "$SCOPES" >/dev/null
  gc compute instances update "$VM" --zone "$ZONE" --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring >/dev/null
  gc compute instances start "$VM" --zone "$ZONE" >/dev/null
  REBOOT=started
fi
if [ "$(gcv compute instances describe "$VM" --zone "$ZONE" --format='value(deletionProtection)')" != True ]; then
  gc compute instances update "$VM" --zone "$ZONE" --deletion-protection >/dev/null
fi
if [ "$REBOOT" = 1 ]; then
  echo "  - restarting the server for its updates"
  ssh_vm 'sudo systemctl reboot' >/dev/null 2>&1 || true
  sleep 30
fi
if [ -n "$REBOOT" ]; then
  _i=0
  until ssh_vm 'true' >/dev/null 2>&1; do
    _i=$((_i + 1))
    [ "$_i" -lt 30 ] || { echo "FAIL: the server didn't come back after its restart" >&2; exit 1; }
    sleep 10
  done
fi
HEALTH_SLEEP=5 wait_healthy "$HOST" 60 || { echo "FAIL: https://$HOST doesn't answer" >&2; exit 1; }
ssh_vm 'sudo docker ps --format "{{.Names}} {{.Status}}"; sudo systemctl is-active latchkey-sentinel auditd latchkey-update-apps.timer | tr "\n" " "; echo; mokutil --sb-state 2>/dev/null || true'

echo "• alerts"
TOKEN=$(gcloud auth print-access-token 2>/dev/null)
mask "$TOKEN"
PROJECT="$PROJECT" HOST="$HOST" ALERT_EMAIL="$ALERT_EMAIL" OWNER_EMAIL="$OWNER" TRUSTED_EMAILS="$INFRA_SA,$HN_SA" TOKEN="$TOKEN" \
  python3 -I deploy/alerts.py | tee "$tmp/alerts.out"
if grep -q '^CREATED .*sentinel warning' "$tmp/alerts.out"; then
  echo "• one test alert to $ALERT_EMAIL (the sentinel's path, end to end)"
  sleep 60 # a new alert policy takes a moment to start matching
  ssh_vm 'sudo /usr/local/sbin/latchkey-sentinel --test'
fi

echo "• SSH closed to the internet (only the IAP tunnel remains)"
for rule in allow-ssh default-allow-ssh default-allow-rdp default-allow-internal; do
  if gcv compute firewall-rules describe "$rule" >/dev/null; then
    gc compute firewall-rules delete "$rule" >/dev/null
    echo "  - firewall rule $rule deleted"
  fi
done
echo "The relay's server is hardened. Alerts go to $ALERT_EMAIL."
