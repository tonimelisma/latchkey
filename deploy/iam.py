"""Small JSON checks for deploy/harden.sh (gcloud's JSON output on stdin). Exit status is the
answer; tested by deploy/tests/test_iam.py.

  is-owner EMAIL                 the IAM policy makes EMAIL (user:) a project owner
  has-role MEMBER ROLE           the IAM policy grants ROLE to MEMBER ("serviceAccount:...")
  add-iap-audit                  prints the IAM policy with IAP's data access log turned on;
                                 fails (prints nothing) when it already is
  sentinel-config [--existing FILE] [--user NAME]...
                                 the OS Login profile to the sentinel's settings
                                 (deploy/server/host/sentinel.py): the owner's accounts, with
                                 those in FILE (the server's settings so far) and the users named
  metadata-ok                    the VM's metadata turns on OS Login and blocks project SSH keys
  vm-ok SA SCOPES                the VM runs as SA with exactly SCOPES (comma-separated), with
                                 Secure Boot, vTPM and integrity monitoring on
"""

import json
import sys


def is_owner(policy, email):
    return has_role(policy, "user:" + email, "roles/owner")


def has_role(policy, member, role):
    return any(b.get("role") == role and member in b.get("members", []) and not b.get("condition")
               for b in policy.get("bindings", []))


def add_iap_audit(policy):
    """The policy with DATA_READ and ADMIN_READ audit logs on for iap.googleapis.com, or None
    when both already are (or every service's are)."""
    want = {"DATA_READ", "ADMIN_READ"}
    configs = policy.setdefault("auditConfigs", [])
    for c in configs:
        if c.get("service") in ("iap.googleapis.com", "allServices"):
            have = {lc.get("logType") for lc in c.get("auditLogConfigs", []) if not lc.get("exemptedMembers")}
            want -= have
    if not want:
        return None
    entry = next((c for c in configs if c.get("service") == "iap.googleapis.com"), None)
    if entry is None:
        entry = {"service": "iap.googleapis.com", "auditLogConfigs": []}
        configs.append(entry)
    for kind in sorted(want):
        entry["auditLogConfigs"].append({"logType": kind})
    return policy


def sentinel_config(profile, existing=None, extra_users=()):
    """The owners' OS Login users and uids: the profile's (the account running harden.sh), the
    server's settings so far (earlier runs, by the owner or by latchkey-infra), and extra users
    (the automation service accounts, sa_<unique id>, whose uids only the server knows)."""
    accounts = profile.get("posixAccounts") or []
    users = {a["username"] for a in accounts if a.get("username")}
    uids = {str(a["uid"]) for a in accounts if a.get("uid")}
    if not users or not uids:
        raise SystemExit("FAIL: the OS Login profile has no account (has OS Login been used once?)")
    existing = existing if isinstance(existing, dict) else {}
    users |= {u for u in existing.get("owner_users", []) if isinstance(u, str) and u}
    uids |= {str(u) for u in existing.get("owner_uids", []) if str(u).isdigit()}
    users |= {u for u in extra_users if u}
    return {"owner_users": sorted(users), "owner_uids": sorted(uids)}


def vm_ok(vm, sa, scopes):
    accounts = vm.get("serviceAccounts") or []
    if len(accounts) != 1 or accounts[0].get("email") != sa:
        return False
    if set(accounts[0].get("scopes", [])) != set(scopes.split(",")):
        return False
    shield = vm.get("shieldedInstanceConfig") or {}
    return bool(shield.get("enableSecureBoot") and shield.get("enableVtpm") and shield.get("enableIntegrityMonitoring"))


def metadata_ok(vm):
    items = {i.get("key"): i.get("value") for i in (vm.get("metadata") or {}).get("items", [])}
    return items.get("enable-oslogin", "").upper() == "TRUE" and items.get("block-project-ssh-keys", "").upper() == "TRUE"


def main(argv):
    raw = sys.stdin.read()
    data = json.loads(raw) if raw.strip() else {}
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "metadata-ok":
        return 0 if metadata_ok(data) else 1
    if cmd == "is-owner":
        return 0 if is_owner(data, argv[2]) else 1
    if cmd == "has-role":
        return 0 if has_role(data, argv[2], argv[3]) else 1
    if cmd == "add-iap-audit":
        new = add_iap_audit(data)
        if new is None:
            return 1
        json.dump(new, sys.stdout)
        return 0
    if cmd == "sentinel-config":
        args, existing, extra = argv[2:], None, []
        while args:
            if args[0] == "--existing" and len(args) > 1:
                try:
                    with open(args[1]) as f:
                        raw_old = f.read()
                    existing = json.loads(raw_old) if raw_old.strip() else None
                except (OSError, ValueError):
                    existing = None
                args = args[2:]
            elif args[0] == "--user" and len(args) > 1:
                extra.append(args[1])
                args = args[2:]
            else:
                print(__doc__, file=sys.stderr)
                return 2
        json.dump(sentinel_config(data, existing, extra), sys.stdout)
        print()
        return 0
    if cmd == "vm-ok":
        return 0 if vm_ok(data, argv[2], argv[3]) else 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
