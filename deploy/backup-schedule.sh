#!/bin/sh
# Turns on a nightly copy (snapshot) of the hosted relay's server disk in Google Cloud, kept for
# 14 days (Toni, 2026-10-25). The disk holds the relay's one database: accounts, passkeys, and
# pairings. Reads the VM, project and zone from the repository's .env, like deploy/deploy.sh.
# Safe to rerun: it creates the schedule and attaches it only when missing.
# To restore: create a disk from a snapshot in the Google Cloud console and start the VM from it.
set -eu
LC_ALL=C
export LC_ALL
cd "$(dirname "$0")/.."
. deploy/lib.sh
scripts/link-local-files.sh
load_env ./.env
: "${DEPLOY_VM:?missing in .env}" "${DEPLOY_PROJECT:?missing in .env}" "${DEPLOY_ZONE:?missing in .env}"
check_host DEPLOY_VM "$DEPLOY_VM"
check_host DEPLOY_PROJECT "$DEPLOY_PROJECT"
check_host DEPLOY_ZONE "$DEPLOY_ZONE"

POLICY=latchkey-nightly
REGION=${DEPLOY_ZONE%-*}

DISK=$(gcloud compute instances describe "$DEPLOY_VM" --project "$DEPLOY_PROJECT" --zone "$DEPLOY_ZONE" \
  --format='value(disks[0].source.basename())')
check_host "the VM's disk name" "$DISK"

if gcloud compute resource-policies describe "$POLICY" --project "$DEPLOY_PROJECT" --region "$REGION" >/dev/null 2>&1; then
  echo "• schedule $POLICY exists"
else
  echo "• creating schedule $POLICY (every night at 09:00 UTC, kept 14 days)"
  gcloud compute resource-policies create snapshot-schedule "$POLICY" --project "$DEPLOY_PROJECT" --region "$REGION" \
    --daily-schedule --start-time 09:00 --max-retention-days 14 \
    --on-source-disk-delete keep-auto-snapshots --description "Nightly copy of the Latchkey relay's server disk" >/dev/null
fi

ATTACHED=$(gcloud compute disks describe "$DISK" --project "$DEPLOY_PROJECT" --zone "$DEPLOY_ZONE" \
  --format='value(resourcePolicies)')
case $ATTACHED in
  *"/resourcePolicies/$POLICY"*) echo "• the server's disk already uses it" ;;
  *)
    echo "• attaching it to the server's disk"
    gcloud compute disks add-resource-policies "$DISK" --project "$DEPLOY_PROJECT" --zone "$DEPLOY_ZONE" \
      --resource-policies "$POLICY" >/dev/null
    ;;
esac
echo "Nightly copies are on."
