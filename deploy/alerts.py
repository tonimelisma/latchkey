"""Sets up the relay server's alerts in Google Cloud Monitoring, all emailed to the owner.

Run by deploy/harden.sh, which passes everything in the environment:
  PROJECT       the Google Cloud project        HOST         the relay's public host name
  ALERT_EMAIL   where alerts go                 OWNER_EMAIL  the Google account that runs it
  TOKEN         an access token for the API (gcloud auth print-access-token)

Alerts (each named "Latchkey: ..." and created or updated in place, so reruns are safe):
- the sentinel reported a WARNING (deploy/server/host/sentinel.py);
- the cloud project changed: an admin action by anyone but Google's own service agents
  (firewall, VM, metadata and SSH keys, IAM, service accounts, ...);
- someone other than the owner went through the IAP tunnel to the server;
- the sentinel went silent for 30 minutes (stopped, killed, or the server down);
- the relay didn't answer https://HOST/healthz from Google's checkers for 10 minutes.
Prints the names of the alerts it created, so harden.sh can send one test alert the first time.
Standard library only; the pure parts are tested by deploy/tests/test_alerts.py.
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

PREFIX = "Latchkey: "
CHANNEL_NAME = "Latchkey alerts"
HEARTBEAT_METRIC = "latchkey_sentinel_heartbeat"
UPTIME_NAME = "Latchkey relay"
GOOGLE_AGENTS = r"@(compute-system\.iam|cloudservices|gcp-sa-[a-z0-9-]+\.iam|container-engine-robot\.iam)\.gserviceaccount\.com$"


def sentinel_filter(project):
    return f'logName="projects/{project}/logs/latchkey-sentinel" AND severity>=WARNING'


def cloud_change_filter(project):
    return (
        f'logName="projects/{project}/logs/cloudaudit.googleapis.com%2Factivity" AND '
        f'NOT protoPayload.authenticationInfo.principalEmail=~"{GOOGLE_AGENTS}"'
    )


def iap_filter(project, owner):
    return (
        f'logName="projects/{project}/logs/cloudaudit.googleapis.com%2Fdata_access" AND '
        f'protoPayload.serviceName="iap.googleapis.com" AND '
        f'protoPayload.authenticationInfo.principalEmail!="{owner}"'
    )


def heartbeat_filter(project):
    return f'logName="projects/{project}/logs/latchkey-sentinel" AND jsonPayload.event="heartbeat"'


def log_policy(name, log_filter, labels, doc, channel):
    return {
        "displayName": PREFIX + name,
        "combiner": "OR",
        "enabled": True,
        "documentation": {"mimeType": "text/markdown", "content": doc},
        "conditions": [{
            "displayName": name,
            "conditionMatchedLog": {"filter": log_filter, "labelExtractors": labels},
        }],
        "alertStrategy": {"notificationRateLimit": {"period": "300s"}, "autoClose": "1800s"},
        "notificationChannels": [channel],
    }


def policies(project, host, owner, channel, uptime_id):
    what_to_do = (
        "If this wasn't you: open the server's log in Cloud Logging "
        f"(log `latchkey-sentinel` in project `{project}`) and docs/threat-model.md, "
        "\"If the server is broken into\"."
    )
    out = [
        log_policy(
            "sentinel warning", sentinel_filter(project),
            {"event": "EXTRACT(jsonPayload.event)", "message": "EXTRACT(jsonPayload.message)"},
            "The sentinel on the relay's server saw something that shouldn't happen there. " + what_to_do,
            channel,
        ),
        log_policy(
            "cloud project changed", cloud_change_filter(project),
            {"method": "EXTRACT(protoPayload.methodName)", "who": "EXTRACT(protoPayload.authenticationInfo.principalEmail)"},
            "Someone changed the relay's Google Cloud project (its firewall, server, keys or "
            "permissions). Expected when you ran deploy/harden.sh or changed it yourself. " + what_to_do,
            channel,
        ),
        log_policy(
            "server sign-in by someone else", iap_filter(project, owner),
            {"who": "EXTRACT(protoPayload.authenticationInfo.principalEmail)", "method": "EXTRACT(protoPayload.methodName)"},
            "Someone other than the owner tried to reach the relay's server through Google's IAP tunnel. " + what_to_do,
            channel,
        ),
        {
            "displayName": PREFIX + "sentinel silent",
            "combiner": "OR",
            "enabled": True,
            "documentation": {"mimeType": "text/markdown", "content":
                "The sentinel on the relay's server sent no heartbeat for 30 minutes: it was "
                "stopped or killed, or the server is down. " + what_to_do},
            "conditions": [{
                "displayName": "no heartbeat for 30 minutes",
                "conditionAbsent": {
                    "filter": f'metric.type="logging.googleapis.com/user/{HEARTBEAT_METRIC}" AND resource.type="gce_instance"',
                    "duration": "1800s",
                    "aggregations": [{"alignmentPeriod": "600s", "perSeriesAligner": "ALIGN_SUM"}],
                },
            }],
            "alertStrategy": {"autoClose": "1800s"},
            "notificationChannels": [channel],
        },
    ]
    if uptime_id:
        out.append({
            "displayName": PREFIX + "relay not answering",
            "combiner": "OR",
            "enabled": True,
            "documentation": {"mimeType": "text/markdown", "content":
                f"https://{host}/healthz didn't answer Google's checkers for 10 minutes. A nightly "
                "update reboot takes about a minute and doesn't trigger this."},
            "conditions": [{
                "displayName": "health check failing",
                "conditionThreshold": {
                    "filter": f'metric.type="monitoring.googleapis.com/uptime_check/check_passed" AND '
                              f'metric.label.check_id="{uptime_id}" AND resource.type="uptime_url"',
                    "aggregations": [{
                        "alignmentPeriod": "1200s", "perSeriesAligner": "ALIGN_NEXT_OLDER",
                        "crossSeriesReducer": "REDUCE_COUNT_FALSE", "groupByFields": ["resource.label.host"],
                    }],
                    "comparison": "COMPARISON_GT",
                    "thresholdValue": 1,
                    "duration": "600s",
                    "trigger": {"count": 1},
                },
            }],
            "alertStrategy": {"autoClose": "1800s"},
            "notificationChannels": [channel],
        })
    return out


def uptime_config(project, host):
    return {
        "displayName": UPTIME_NAME,
        "monitoredResource": {"type": "uptime_url", "labels": {"project_id": project, "host": host}},
        "httpCheck": {"path": "/healthz", "port": 443, "useSsl": True, "validateSsl": True, "requestMethod": "GET"},
        "period": "300s",
        "timeout": "10s",
    }


class Api:
    def __init__(self, project, token):
        self.project, self.token = project, token

    def call(self, method, url, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": "Bearer " + self.token,
            "Content-Type": "application/json",
            "x-goog-user-project": self.project,
        })
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                raw = r.read()
        except urllib.error.HTTPError as e:
            if e.code == 404 and method == "GET":
                return None
            detail = e.read().decode(errors="replace")[:500]
            raise SystemExit(f"FAIL: {method} {url.split('?')[0]}: {e.code} {detail}") from None
        return json.loads(raw) if raw else {}

    def list_all(self, url, key):
        items, token = [], ""
        while True:
            sep = "&" if "?" in url else "?"
            page = self.call("GET", url + (f"{sep}pageToken={urllib.parse.quote(token)}" if token else "")) or {}
            items += page.get(key, [])
            token = page.get("nextPageToken", "")
            if not token:
                return items


def main():
    project, host = os.environ["PROJECT"], os.environ["HOST"]
    email, owner = os.environ["ALERT_EMAIL"], os.environ["OWNER_EMAIL"]
    api = Api(project, os.environ["TOKEN"])
    mon = f"https://monitoring.googleapis.com/v3/projects/{project}"
    created = []

    channels = api.list_all(f"{mon}/notificationChannels", "notificationChannels")
    channel = next((c["name"] for c in channels if c.get("displayName") == CHANNEL_NAME), None)
    want_channel = {"type": "email", "displayName": CHANNEL_NAME, "labels": {"email_address": email}, "enabled": True}
    if channel is None:
        channel = api.call("POST", f"{mon}/notificationChannels", want_channel)["name"]
        print("• alert email channel created")
    else:
        api.call("PATCH", f"https://monitoring.googleapis.com/v3/{channel}?updateMask=labels,enabled", want_channel)

    metric_url = f"https://logging.googleapis.com/v2/projects/{project}/metrics"
    want_metric = {"name": HEARTBEAT_METRIC, "description": "Latchkey sentinel heartbeats", "filter": heartbeat_filter(project)}
    if api.call("GET", f"{metric_url}/{HEARTBEAT_METRIC}") is None:
        api.call("POST", metric_url, want_metric)
        print("• heartbeat metric created")
    else:
        api.call("PUT", f"{metric_url}/{HEARTBEAT_METRIC}", want_metric)

    checks = api.list_all(f"{mon}/uptimeCheckConfigs", "uptimeCheckConfigs")
    check = next((c for c in checks if c.get("displayName") == UPTIME_NAME), None)
    if check is None:
        check = api.call("POST", f"{mon}/uptimeCheckConfigs", uptime_config(project, host))
        print("• uptime check created")
    uptime_id = check["name"].rsplit("/", 1)[-1]

    existing = {p["displayName"]: p["name"] for p in api.list_all(f"{mon}/alertPolicies", "alertPolicies")}
    for policy in policies(project, host, owner, channel, uptime_id):
        name = existing.get(policy["displayName"])
        if name is None:
            api.call("POST", f"{mon}/alertPolicies", policy)
            created.append(policy["displayName"])
            print(f"• alert created: {policy['displayName']}")
        else:
            mask = "displayName,documentation,conditions,combiner,enabled,alertStrategy,notificationChannels"
            api.call("PATCH", f"https://monitoring.googleapis.com/v3/{name}?updateMask={mask}", policy)
    if created:
        print("CREATED " + ",".join(created))


if __name__ == "__main__":
    sys.exit(main())
