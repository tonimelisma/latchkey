"""Makes DNS and the email sending domain right for the hosted relay (idempotent).

- Cloudflare: an A record for HOST -> IP, not proxied (Caddy on the VM gets the certificate,
  and the agent WebSocket goes straight through).
- Cloudflare: CAA records on HOST, so only the two authorities Caddy uses (Let's Encrypt, and
  ZeroSSL, whose certificates are issued by Sectigo) may issue certificates for it.
- Resend: a sending domain for HOST, with its SPF, DKIM and bounce records created in Cloudflare,
  then verification requested.
- Cloudflare: a DMARC policy for HOST that tells receivers to reject mail that isn't the relay's.
  Alignment is relaxed on purpose: mail is from no-reply@HOST, signed by Resend with DKIM
  d=HOST, with the envelope sender on send.HOST (a subdomain, so SPF aligns only when relaxed).
Reads CLOUDFLARE_API_TOKEN and RESEND_ADMIN_KEY (full access) from the environment; never prints
them. Without RESEND_ADMIN_KEY the email domain step is skipped, so a redeploy needs only the
send-only key.

The record-building logic is tested without network by deploy/tests/test_dns_and_email.py.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

CF = "https://api.cloudflare.com/client/v4"
RS = "https://api.resend.com"

DMARC_POLICY = "v=DMARC1; p=reject; adkim=r; aspf=r"
# Caddy's default certificate authorities: Let's Encrypt, then ZeroSSL (issued by Sectigo).
CAA_ISSUERS = ("letsencrypt.org", "sectigo.com")


def policy_records(host):
    """The records Resend doesn't list: the DMARC policy and who may issue certificates."""
    records = [{"type": "TXT", "name": f"_dmarc.{host}", "content": DMARC_POLICY}]
    for issuer in CAA_ISSUERS:
        records.append({"type": "CAA", "name": host, "data": {"flags": 0, "tag": "issue", "value": issuer}})
    return records


def full_name(name, zone):
    """Resend lists names relative to the zone; Cloudflare wants them whole."""
    return name if name == zone or name.endswith("." + zone) else f"{name}.{zone}"


def _unquoted(text):
    return (text or "").strip().strip('"')


def _version_tag(content):
    """'v=spf1', 'v=DMARC1', 'v=DKIM1': a name holds at most one record of each kind."""
    content = _unquoted(content)
    return content.split(";")[0].split()[0].lower() if content.lower().startswith("v=") else ""


def _caa_text(record):
    data = record.get("data")
    if data:
        return f'{data.get("flags", 0)} {data.get("tag")} "{data.get("value")}"'
    return (record.get("content") or "").strip()


def plan(want, existing):
    """What to do so that `want` exists, given the records Cloudflare has of that type and name.

    Returns (action, record id, request body): action is "none", "create" or "update".
    """
    body = {"type": want["type"], "name": want["name"], "ttl": 1}
    if want["type"] == "CAA":
        body["data"] = want["data"]
        if any(_caa_text(r).replace('"', "") == _caa_text(want).replace('"', "") for r in existing):
            return ("none", None, body)
        return ("create", None, body)  # one record per authority, side by side
    body["content"] = want["content"]
    body["proxied"] = False
    if want.get("priority") is not None:
        body["priority"] = want["priority"]
    if want["type"] == "TXT":
        if any(_unquoted(r.get("content")) == _unquoted(want["content"]) for r in existing):
            return ("none", None, body)
        tag = _version_tag(want["content"])
        same_kind = [r for r in existing if tag and _version_tag(r.get("content")) == tag]
        if same_kind:  # e.g. an older, weaker DMARC policy: replaced, never doubled
            return ("update", same_kind[0]["id"], body)
        return ("create", None, body)
    if existing:
        if existing[0].get("content") != want["content"] or existing[0].get("proxied"):
            return ("update", existing[0]["id"], body)
        return ("none", None, body)
    return ("create", None, body)


def alignment_problems(resend_records, host, zone):
    """Why mail would fail the DMARC policy: DKIM must sign as HOST or a subdomain of it."""
    dkim = [r for r in resend_records if r.get("record") == "DKIM" or "._domainkey" in r.get("name", "")]
    if not dkim:
        return ["Resend lists no DKIM record for this domain"]
    problems = []
    for r in dkim:
        name = full_name(r["name"], zone)
        signing_domain = name.split("._domainkey.", 1)[-1]
        if not (signing_domain == host or signing_domain.endswith("." + host)):
            problems.append(f"the DKIM record {name} signs for a domain outside {host}")
    return problems


def admin_key_reminder(status):
    """One line once the full-access key has done its work."""
    if status == "verified":
        return "  RESEND_ADMIN_KEY is no longer needed (the sending domain is verified): remove it from .env"
    return ""


def call(url, method="GET", body=None, token=""):
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body else None)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", "latchkey-deploy")
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {url.split('?')[0]}: HTTP {e.code}: {e.read().decode()[:300]}")


def main():
    host, zone_name, ip = os.environ["HOST"], os.environ["ZONE_NAME"], os.environ["IP"]
    cf_token = os.environ["CLOUDFLARE_API_TOKEN"]
    zone = call(f"{CF}/zones?name={zone_name}", token=cf_token)["result"]
    if not zone:
        sys.exit(f"Cloudflare zone {zone_name} not visible to this token")
    records_url = f"{CF}/zones/{zone[0]['id']}/dns_records"

    def upsert(want):
        want = dict(want, name=full_name(want["name"], zone_name))
        existing = call(f"{records_url}?type={want['type']}&name={want['name']}", token=cf_token)["result"]
        action, record_id, body = plan(want, existing)
        if action == "create":
            call(records_url, "POST", body, cf_token)
        elif action == "update":
            call(f"{records_url}/{record_id}", "PUT", body, cf_token)
        else:
            return
        print(f"  DNS {want['type']} {want['name']}: {action}d")

    dmarc, *caa = policy_records(host)
    upsert({"type": "A", "name": host, "content": ip})
    for record in caa:
        upsert(record)

    rs_token = os.environ.get("RESEND_ADMIN_KEY", "")
    if not rs_token:
        upsert(dmarc)
        print("  email domain: skipped (no RESEND_ADMIN_KEY; fine once the domain is verified)")
        return
    domains = call(f"{RS}/domains", token=rs_token).get("data", [])
    dom = next((d for d in domains if d["name"] == host), None)
    if dom is None:
        dom = call(f"{RS}/domains", "POST", {"name": host}, rs_token)
    detail = call(f"{RS}/domains/{dom['id']}", token=rs_token)
    for r in detail.get("records", []):
        upsert({"type": r["type"], "name": r["name"], "content": r["value"], "priority": r.get("priority")})
    problems = alignment_problems(detail.get("records", []), host, zone_name)
    if problems:
        sys.exit("DMARC policy not set, the relay's mail would be rejected: " + "; ".join(problems))
    upsert(dmarc)
    status = detail.get("status")
    if status != "verified":
        call(f"{RS}/domains/{dom['id']}/verify", "POST", {}, rs_token)
        for _ in range(30):
            time.sleep(10)
            status = call(f"{RS}/domains/{dom['id']}", token=rs_token).get("status")
            if status == "verified":
                break
    print(f"  email domain {host}: {status}")
    if admin_key_reminder(status):
        print(admin_key_reminder(status))


if __name__ == "__main__":
    main()
