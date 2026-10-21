"""Makes DNS and the email sending domain right for the hosted relay (idempotent).

- Cloudflare: an A record for HOST -> IP, not proxied (Caddy on the VM gets the certificate,
  and the agent WebSocket goes straight through).
- Resend: a sending domain for HOST, with its SPF, DKIM and bounce records created in Cloudflare,
  then verification requested.
Reads CLOUDFLARE_API_TOKEN and RESEND_API_KEY from the environment; never prints them.
"""
import json
import os
import sys
import time
import urllib.request

HOST, ZONE_NAME, IP = os.environ["HOST"], os.environ["ZONE_NAME"], os.environ["IP"]


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


CF = "https://api.cloudflare.com/client/v4"
cf_token = os.environ["CLOUDFLARE_API_TOKEN"]
zone = call(f"{CF}/zones?name={ZONE_NAME}", token=cf_token)["result"]
if not zone:
    sys.exit(f"Cloudflare zone {ZONE_NAME} not visible to this token")
zone_id = zone[0]["id"]


def upsert(rtype, name, content, priority=None):
    name = name if name.endswith(ZONE_NAME) else f"{name}.{ZONE_NAME}"
    existing = call(f"{CF}/zones/{zone_id}/dns_records?type={rtype}&name={name}", token=cf_token)["result"]
    body = {"type": rtype, "name": name, "content": content, "ttl": 1, "proxied": False}
    if priority is not None:
        body["priority"] = priority
    if rtype == "TXT":
        same = [r for r in existing if r["content"].strip('"') == content.strip('"')]
        if same:
            return
        call(f"{CF}/zones/{zone_id}/dns_records", "POST", body, cf_token)
    elif existing:
        if existing[0]["content"] != content or existing[0].get("proxied"):
            call(f"{CF}/zones/{zone_id}/dns_records/{existing[0]['id']}", "PUT", body, cf_token)
    else:
        call(f"{CF}/zones/{zone_id}/dns_records", "POST", body, cf_token)
    print(f"  DNS {rtype} {name}")


upsert("A", HOST, IP)

RS = "https://api.resend.com"
rs_token = os.environ["RESEND_API_KEY"]
domains = call(f"{RS}/domains", token=rs_token).get("data", [])
dom = next((d for d in domains if d["name"] == HOST), None)
if dom is None:
    dom = call(f"{RS}/domains", "POST", {"name": HOST}, rs_token)
detail = call(f"{RS}/domains/{dom['id']}", token=rs_token)
for r in detail.get("records", []):
    upsert(r["type"], r["name"], r["value"], r.get("priority"))
if detail.get("status") != "verified":
    call(f"{RS}/domains/{dom['id']}/verify", "POST", {}, rs_token)
    for _ in range(30):
        time.sleep(10)
        status = call(f"{RS}/domains/{dom['id']}", token=rs_token).get("status")
        if status == "verified":
            break
    print(f"  email domain {HOST}: {status}")
else:
    print(f"  email domain {HOST}: verified")
