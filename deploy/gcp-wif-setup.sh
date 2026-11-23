#!/bin/sh
# One-time Google Cloud setup for GitHub Actions, run by the owner in Google Cloud Shell (signed
# in as the project's owner). Safe to rerun: what exists is kept, and IAM bindings are added only
# when missing.
#
#   sh deploy/gcp-wif-setup.sh --project PROJECT --zone ZONE --vm VM [--buckets a,b]
#   (or PROJECT=… ZONE=… VM=… [APP_BUCKETS=…] sh deploy/gcp-wif-setup.sh)
#
# The project, zone and VM are private values of this deployment (CLAUDE.md), so they are
# arguments, never written here.
#
# Workload Identity Federation lets a GitHub Actions job sign in to Google Cloud with GitHub's
# own short-lived identity token: no service account key exists anywhere. This makes:
# - the pool "github" with the provider "github-actions", trusting GitHub's token issuer only for
#   jobs of tonimelisma/latchkey and tonimelisma/hackernews running on main (repository_dispatch
#   and workflow_dispatch run there too);
# - latchkey-infra, the identity of latchkey's infra workflow (.github/workflows/infra.yml: the
#   relay's configuration and deploy/harden.sh). Only a job of tonimelisma/latchkey in its
#   environment "infra" may act as it, so the environment's approval rule (if the owner sets one)
#   also guards Google Cloud. Its roles are what deploy/harden.sh and deploy/deploy.sh do:
#   project IAM (harden's IAM edits), the VM and its firewall, enabled services, alerts and the
#   heartbeat metric, reading service accounts, acting as the VM's own account relay-vm, SSH
#   through IAP with OS Login as an admin on the VM only, and the app buckets' IAM;
# - hackernews-admin, for tonimelisma/hackernews's admin jobs: SSH through IAP (port 22 only) with
#   OS Login as an admin on the VM only, and reading the project's compute resources.
# Both identities are expected users of the IAP tunnel and the server: deploy/harden.sh leaves
# them out of the "server sign-in by someone else" alert and counts their sessions as the
# owner's (docs/threat-model.md, "The relay's server"). Every change made here emails the owner
# ("Latchkey: cloud project changed"), as any admin action does.
#
# Prints only what goes into the repositories' secrets (in each repository: Settings → Secrets
# and variables → Actions; for latchkey, in the environment "infra"). They are secrets, not
# variables, because they hold the project's ID and number and workflow logs are public: GitHub
# hides secrets in logs.
set -eu
PROJECT=${PROJECT-} ZONE=${ZONE-} VM=${VM-} APP_BUCKETS=${APP_BUCKETS-}
while [ $# -gt 0 ]; do
  case $1 in
    --project) PROJECT=$2; shift 2 ;;
    --zone) ZONE=$2; shift 2 ;;
    --vm) VM=$2; shift 2 ;;
    --buckets) APP_BUCKETS=$2; shift 2 ;;
    *) sed -n '2,10p' "$0" >&2; exit 2 ;;
  esac
done
for v in PROJECT ZONE VM; do
  eval "val=\${$v}"
  # shellcheck disable=SC2154 # set by the eval
  case $val in '' | [!a-z0-9]* | *[!a-z0-9.-]*) echo "FAIL: $v must be set (lowercase letters, digits, dots, hyphens)" >&2; exit 2 ;; esac
done
case $APP_BUCKETS in *[!a-z0-9._,-]* | ,* | *, | *,,*) echo "FAIL: --buckets must be bucket names separated by commas" >&2; exit 2 ;; esac

POOL=github
PROVIDER=github-actions
OWNER_LOGIN=tonimelisma
THIS_REPO=tonimelisma/latchkey
HN_REPO=tonimelisma/hackernews
INFRA_SA=latchkey-infra@$PROJECT.iam.gserviceaccount.com
HN_SA=hackernews-admin@$PROJECT.iam.gserviceaccount.com
VM_SA=relay-vm@$PROJECT.iam.gserviceaccount.com
g() { gcloud "$@" --project "$PROJECT" --quiet; }
gq() { gcloud "$@" --project "$PROJECT" --quiet >/dev/null 2>&1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# has_binding FILE MEMBER ROLE: the IAM policy (JSON) grants ROLE to MEMBER (with or without a
# condition).
has_binding() {
  python3 -I -c 'import json,sys
p=json.load(open(sys.argv[1])) if open(sys.argv[1]).read().strip() else {}
sys.exit(0 if any(b.get("role")==sys.argv[3] and sys.argv[2] in b.get("members",[]) for b in p.get("bindings",[])) else 1)' "$@"
}
# project_role MEMBER ROLE [CONDITION]: a project binding, added when missing.
project_role() {
  g projects get-iam-policy "$PROJECT" --format=json >"$tmp/project.json"
  has_binding "$tmp/project.json" "$1" "$2" && return 0
  if [ -n "${3-}" ]; then
    g projects add-iam-policy-binding "$PROJECT" --member "$1" --role "$2" --condition "$3" >/dev/null
  else
    g projects add-iam-policy-binding "$PROJECT" --member "$1" --role "$2" --condition=None >/dev/null
  fi
  echo "  - $2 for ${1%%@*}"
}
# vm_role MEMBER ROLE: a binding on the VM alone.
vm_role() {
  g compute instances get-iam-policy "$VM" --zone "$ZONE" --format=json >"$tmp/vm.json"
  has_binding "$tmp/vm.json" "$1" "$2" && return 0
  g compute instances add-iam-policy-binding "$VM" --zone "$ZONE" --member "$1" --role "$2" >/dev/null
  echo "  - $2 on the VM for ${1%%@*}"
}
# sa_role SA MEMBER ROLE: a binding on a service account.
sa_role() {
  g iam service-accounts get-iam-policy "$1" --format=json >"$tmp/sa.json"
  has_binding "$tmp/sa.json" "$2" "$3" && return 0
  g iam service-accounts add-iam-policy-binding "$1" --member "$2" --role "$3" >/dev/null
  echo "  - $3 on ${1%%@*} for ${2##*/}"
}

echo "• services"
for api in iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com; do
  g services list --enabled --format='value(config.name)' | grep -qx "$api" || g services enable "$api" >/dev/null
done
NUMBER=$(g projects describe "$PROJECT" --format='value(projectNumber)')
case $NUMBER in '' | *[!0-9]*) echo "FAIL: couldn't read the project's number" >&2; exit 1 ;; esac
gq compute instances describe "$VM" --zone "$ZONE" || { echo "FAIL: no VM $VM in $ZONE" >&2; exit 1; }
gq iam service-accounts describe "$VM_SA" || { echo "FAIL: the VM's own account relay-vm doesn't exist yet; run deploy/harden.sh once first" >&2; exit 1; }

echo "• the identity pool and GitHub's provider"
gq iam workload-identity-pools describe "$POOL" --location global ||
  g iam workload-identity-pools create "$POOL" --location global --display-name "GitHub Actions" \
    --description "GitHub Actions jobs of the owner's repositories on main (deploy/gcp-wif-setup.sh)" >/dev/null
# Only these events: pull_request_target and workflow_run also run on main but can run a fork's
# pull request code, which must never become one of these accounts (security review, 2026-11-23).
CONDITION="assertion.repository_owner == '$OWNER_LOGIN' && assertion.repository in ['$THIS_REPO', '$HN_REPO'] && assertion.ref == 'refs/heads/main' && assertion.event_name in ['push', 'schedule', 'workflow_dispatch', 'repository_dispatch']"
MAPPING="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref,attribute.repository_environment=assertion.repository + '@' + ('environment' in assertion ? assertion.environment : '')"
# Rewritten only when it differs: every write is a "cloud project changed" alert.
if g iam workload-identity-pools providers describe "$PROVIDER" --location global --workload-identity-pool "$POOL" \
  --format=json >"$tmp/provider.json" 2>/dev/null; then
  python3 -I -c 'import json,sys
p=json.load(open(sys.argv[1])); m=dict(kv.split("=",1) for kv in sys.argv[3].split(",attribute.") if kv)
m={(k if k.startswith("google.") else "attribute."+k):v for k,v in m.items()}
sys.exit(0 if p.get("attributeCondition")==sys.argv[2] and p.get("attributeMapping")==m else 1)' \
    "$tmp/provider.json" "$CONDITION" "$MAPPING" ||
  g iam workload-identity-pools providers update-oidc "$PROVIDER" --location global --workload-identity-pool "$POOL" \
    --issuer-uri https://token.actions.githubusercontent.com --attribute-mapping "$MAPPING" --attribute-condition "$CONDITION" >/dev/null
else
  g iam workload-identity-pools providers create-oidc "$PROVIDER" --location global --workload-identity-pool "$POOL" \
    --display-name "GitHub" --issuer-uri https://token.actions.githubusercontent.com \
    --attribute-mapping "$MAPPING" --attribute-condition "$CONDITION" >/dev/null
fi
PRINCIPALS=principalSet://iam.googleapis.com/projects/$NUMBER/locations/global/workloadIdentityPools/$POOL

echo "• service accounts"
gq iam service-accounts describe "$INFRA_SA" ||
  g iam service-accounts create latchkey-infra --display-name "Latchkey infra workflow" \
    --description "GitHub Actions: latchkey's infra workflow, environment infra, on main (deploy/gcp-wif-setup.sh)" >/dev/null
gq iam service-accounts describe "$HN_SA" ||
  g iam service-accounts create hackernews-admin --display-name "hackernews admin" \
    --description "GitHub Actions: hackernews admin jobs on main; SSH to the VM only (deploy/gcp-wif-setup.sh)" >/dev/null
sleep 5

echo "• who may act as them"
sa_role "$INFRA_SA" "$PRINCIPALS/attribute.repository_environment/$THIS_REPO@infra" roles/iam.workloadIdentityUser
sa_role "$HN_SA" "$PRINCIPALS/attribute.repository/$HN_REPO" roles/iam.workloadIdentityUser

echo "• latchkey-infra's roles"
for role in roles/resourcemanager.projectIamAdmin roles/compute.instanceAdmin.v1 roles/compute.securityAdmin \
  roles/compute.viewer roles/serviceusage.serviceUsageAdmin roles/iam.serviceAccountViewer \
  roles/monitoring.editor roles/logging.configWriter roles/iap.tunnelResourceAccessor; do
  project_role "serviceAccount:$INFRA_SA" "$role"
done
vm_role "serviceAccount:$INFRA_SA" roles/compute.osAdminLogin
sa_role "$VM_SA" "serviceAccount:$INFRA_SA" roles/iam.serviceAccountUser
for bucket in $(printf '%s' "$APP_BUCKETS" | tr ',' ' '); do
  gcloud storage buckets get-iam-policy "gs://$bucket" --project "$PROJECT" --format=json >"$tmp/bucket.json"
  has_binding "$tmp/bucket.json" "serviceAccount:$INFRA_SA" roles/storage.admin ||
    gcloud storage buckets add-iam-policy-binding "gs://$bucket" --project "$PROJECT" --quiet \
      --member "serviceAccount:$INFRA_SA" --role roles/storage.admin >/dev/null
done

echo "• hackernews-admin's roles"
project_role "serviceAccount:$HN_SA" roles/compute.viewer
# IAP's tunnel to this VM's SSH port only, not to any other VM the project may get: the condition
# names the VM's internal address (security review, 2026-11-23).
VM_IP=$(g compute instances describe "$VM" --zone "$ZONE" --format='value(networkInterfaces[0].networkIP)')
case $VM_IP in '' | *[!0-9.]*) echo "FAIL: couldn't read the VM's internal address" >&2; exit 1 ;; esac
TUNNEL="destination.ip == '$VM_IP' && destination.port == 22"
g projects get-iam-policy "$PROJECT" --format=json >"$tmp/project.json"
if ! python3 -I -c 'import json,sys
p=json.load(open(sys.argv[1]))
sys.exit(0 if any(b.get("role")=="roles/iap.tunnelResourceAccessor" and sys.argv[2] in b.get("members",[]) and (b.get("condition") or {}).get("expression")==sys.argv[3] for b in p.get("bindings",[])) else 1)' \
  "$tmp/project.json" "serviceAccount:$HN_SA" "$TUNNEL"; then
  # An earlier, wider grant (any VM's port 22) goes first.
  if has_binding "$tmp/project.json" "serviceAccount:$HN_SA" roles/iap.tunnelResourceAccessor; then
    g projects remove-iam-policy-binding "$PROJECT" --member "serviceAccount:$HN_SA" --role roles/iap.tunnelResourceAccessor --all >/dev/null
  fi
  g projects add-iam-policy-binding "$PROJECT" --member "serviceAccount:$HN_SA" --role roles/iap.tunnelResourceAccessor \
    --condition "expression=$TUNNEL,title=ssh-to-$VM,description=SSH through IAP to this VM only" >/dev/null
  echo "  - roles/iap.tunnelResourceAccessor (this VM's SSH only) for hackernews-admin"
fi
vm_role "serviceAccount:$HN_SA" roles/compute.osAdminLogin
sa_role "$VM_SA" "serviceAccount:$HN_SA" roles/iam.serviceAccountUser

echo
echo "Done. Put these in the repositories' Actions secrets:"
echo "  tonimelisma/latchkey, environment infra:"
echo "    GCP_WORKLOAD_IDENTITY_PROVIDER = projects/$NUMBER/locations/global/workloadIdentityPools/$POOL/providers/$PROVIDER"
echo "    GCP_SERVICE_ACCOUNT            = $INFRA_SA"
echo "  tonimelisma/hackernews:"
echo "    GCP_WORKLOAD_IDENTITY_PROVIDER = projects/$NUMBER/locations/global/workloadIdentityPools/$POOL/providers/$PROVIDER"
echo "    GCP_SERVICE_ACCOUNT            = $HN_SA"
echo "Then run deploy/harden.sh once through the infra workflow, so the alerts and the sentinel know both accounts."
