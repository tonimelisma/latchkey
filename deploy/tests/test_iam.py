"""Tests for deploy/iam.py and deploy/alerts.py (no network). Run: make -C relay script-tests."""

import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, "..", name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


iam = load("iam")
alerts = load("alerts")

POLICY = {"bindings": [
    {"role": "roles/owner", "members": ["user:owner@example.com"]},
    {"role": "roles/editor", "members": ["serviceAccount:1-compute@developer.gserviceaccount.com"]},
    {"role": "roles/viewer", "members": ["user:cond@example.com"], "condition": {"expression": "x"}},
]}


class Iam(unittest.TestCase):
    def test_owner(self):
        self.assertTrue(iam.is_owner(POLICY, "owner@example.com"))
        self.assertFalse(iam.is_owner(POLICY, "other@example.com"))

    def test_role(self):
        self.assertTrue(iam.has_role(POLICY, "serviceAccount:1-compute@developer.gserviceaccount.com", "roles/editor"))
        self.assertFalse(iam.has_role(POLICY, "user:cond@example.com", "roles/viewer"))  # conditional doesn't count

    def test_iap_audit_is_added_once(self):
        new = iam.add_iap_audit({"bindings": [], "etag": "e"})
        self.assertEqual(new["auditConfigs"], [{"service": "iap.googleapis.com", "auditLogConfigs": [
            {"logType": "ADMIN_READ"}, {"logType": "DATA_READ"}]}])
        self.assertEqual(new["etag"], "e")  # the update is refused if the policy changed meanwhile
        self.assertIsNone(iam.add_iap_audit(new))

    def test_iap_audit_already_on_for_all_services(self):
        p = {"auditConfigs": [{"service": "allServices", "auditLogConfigs": [{"logType": "DATA_READ"}, {"logType": "ADMIN_READ"}]}]}
        self.assertIsNone(iam.add_iap_audit(p))

    def test_sentinel_config(self):
        prof = {"posixAccounts": [{"username": "owner_example_com", "uid": "34248051", "primary": True}]}
        self.assertEqual(iam.sentinel_config(prof), {"owner_users": ["owner_example_com"], "owner_uids": ["34248051"]})
        with self.assertRaises(SystemExit):
            iam.sentinel_config({})

    def test_metadata(self):
        vm = {"metadata": {"items": [{"key": "enable-oslogin", "value": "TRUE"}, {"key": "block-project-ssh-keys", "value": "true"}]}}
        self.assertTrue(iam.metadata_ok(vm))
        vm["metadata"]["items"][0]["value"] = "FALSE"
        self.assertFalse(iam.metadata_ok(vm))
        self.assertFalse(iam.metadata_ok({}))

    def test_vm(self):
        sa, scopes = "relay-vm@p.iam.gserviceaccount.com", "a,b"
        vm = {"serviceAccounts": [{"email": sa, "scopes": ["b", "a"]}],
              "shieldedInstanceConfig": {"enableSecureBoot": True, "enableVtpm": True, "enableIntegrityMonitoring": True}}
        self.assertTrue(iam.vm_ok(vm, sa, scopes))
        vm["shieldedInstanceConfig"]["enableSecureBoot"] = False
        self.assertFalse(iam.vm_ok(vm, sa, scopes))
        vm["shieldedInstanceConfig"]["enableSecureBoot"] = True
        vm["serviceAccounts"][0]["email"] = "1-compute@developer.gserviceaccount.com"
        self.assertFalse(iam.vm_ok(vm, sa, scopes))


class Alerts(unittest.TestCase):
    def setUp(self):
        self.ps = {p["displayName"]: p for p in alerts.policies("proj", "relay.example.com", "owner@example.com", "projects/proj/notificationChannels/1", "check-1")}

    def test_every_alert_is_there_and_emails_the_owner(self):
        self.assertEqual(sorted(self.ps), sorted("Latchkey: " + n for n in (
            "sentinel warning", "cloud project changed", "server sign-in by someone else", "sentinel silent", "relay not answering")))
        for p in self.ps.values():
            self.assertEqual(p["notificationChannels"], ["projects/proj/notificationChannels/1"])

    def test_sentinel_filter(self):
        f = self.ps["Latchkey: sentinel warning"]["conditions"][0]["conditionMatchedLog"]["filter"]
        self.assertEqual(f, 'logName="projects/proj/logs/latchkey-sentinel" AND severity>=WARNING')

    def test_cloud_changes_leave_out_only_googles_own_agents(self):
        f = alerts.cloud_change_filter("proj")
        self.assertIn("cloudaudit.googleapis.com%2Factivity", f)
        import re
        rx = re.compile(alerts.GOOGLE_AGENTS)
        self.assertTrue(rx.search("service-1@compute-system.iam.gserviceaccount.com"))
        self.assertTrue(rx.search("1@cloudservices.gserviceaccount.com"))
        self.assertFalse(rx.search("relay-vm@proj.iam.gserviceaccount.com"))  # the VM's own account counts
        self.assertFalse(rx.search("1-compute@developer.gserviceaccount.com"))
        self.assertFalse(rx.search("attacker@gmail.com"))

    def test_iap_by_others(self):
        self.assertIn('principalEmail!="owner@example.com"', alerts.iap_filter("proj", "owner@example.com"))

    def test_uptime_alert_needs_a_check(self):
        ps = alerts.policies("proj", "h", "o@e.com", "c", "")
        self.assertNotIn("Latchkey: relay not answering", [p["displayName"] for p in ps])


if __name__ == "__main__":
    unittest.main()
