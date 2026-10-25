"""Tests for the record-building logic of deploy/dns_and_email.py. No network.

Run: python3 -m unittest discover -s deploy/tests -p 'test_*.py' (or `make -C relay script-tests`).
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import dns_and_email as d  # noqa: E402  (importing must not touch the network or need settings)

HOST, ZONE = "relay.example.com", "example.com"


class PolicyRecords(unittest.TestCase):
    def test_dmarc_rejects_with_relaxed_alignment(self):
        dmarc = [r for r in d.policy_records(HOST) if r["type"] == "TXT"]
        self.assertEqual(len(dmarc), 1)
        self.assertEqual(dmarc[0]["name"], "_dmarc.relay.example.com")
        self.assertEqual(dmarc[0]["content"], "v=DMARC1; p=reject; adkim=r; aspf=r")

    def test_caa_allows_only_caddys_two_authorities(self):
        caa = [r for r in d.policy_records(HOST) if r["type"] == "CAA"]
        self.assertEqual({r["name"] for r in caa}, {HOST})
        self.assertEqual(
            sorted((r["data"]["flags"], r["data"]["tag"], r["data"]["value"]) for r in caa),
            [(0, "issue", "letsencrypt.org"), (0, "issue", "sectigo.com")],
        )


class FullName(unittest.TestCase):
    def test_names_relative_to_the_zone_get_it_appended(self):
        self.assertEqual(d.full_name("send.relay", ZONE), "send.relay.example.com")
        self.assertEqual(d.full_name("relay.example.com", ZONE), "relay.example.com")
        self.assertEqual(d.full_name("example.com", ZONE), "example.com")

    def test_a_name_that_merely_ends_like_the_zone_is_still_relative(self):
        self.assertEqual(d.full_name("notexample.com", ZONE), "notexample.com.example.com")


class Plan(unittest.TestCase):
    def test_missing_record_is_created(self):
        want = d.policy_records(HOST)[0]
        action, rid, body = d.plan(want, [])
        self.assertEqual((action, rid), ("create", None))
        self.assertEqual(body["type"], "TXT")
        self.assertEqual(body["name"], "_dmarc.relay.example.com")
        self.assertFalse(body.get("proxied"))

    def test_same_dmarc_is_left_alone_quoted_or_not(self):
        want = d.policy_records(HOST)[0]
        for content in (want["content"], '"' + want["content"] + '"'):
            existing = [{"id": "1", "type": "TXT", "name": want["name"], "content": content}]
            self.assertEqual(d.plan(want, existing)[0], "none")

    def test_weaker_dmarc_is_updated_in_place_not_duplicated(self):
        want = d.policy_records(HOST)[0]
        existing = [{"id": "7", "type": "TXT", "name": want["name"], "content": '"v=DMARC1; p=none"'}]
        action, rid, body = d.plan(want, existing)
        self.assertEqual((action, rid), ("update", "7"))
        self.assertEqual(body["content"], want["content"])

    def test_other_txt_records_at_a_name_are_kept(self):
        # SPF and a site-verification record may share a name: a new value is added beside them.
        want = {"type": "TXT", "name": "send.relay.example.com", "content": "v=spf1 include:x ~all"}
        existing = [{"id": "1", "type": "TXT", "name": want["name"], "content": "google-site-verification=abc"}]
        self.assertEqual(d.plan(want, existing)[0], "create")

    def test_caa_present_in_either_api_form_is_left_alone(self):
        want = [r for r in d.policy_records(HOST) if r["type"] == "CAA"][0]
        by_data = [{"id": "1", "type": "CAA", "name": HOST, "data": {"flags": 0, "tag": "issue", "value": "letsencrypt.org"}}]
        by_content = [{"id": "1", "type": "CAA", "name": HOST, "content": '0 issue "letsencrypt.org"'}]
        self.assertEqual(d.plan(want, by_data)[0], "none")
        self.assertEqual(d.plan(want, by_content)[0], "none")

    def test_second_caa_is_added_beside_the_first(self):
        le, sectigo = [r for r in d.policy_records(HOST) if r["type"] == "CAA"]
        existing = [{"id": "1", "type": "CAA", "name": HOST, "content": '0 issue "letsencrypt.org"'}]
        action, rid, body = d.plan(sectigo, existing)
        self.assertEqual((action, rid), ("create", None))
        self.assertEqual(body["data"], {"flags": 0, "tag": "issue", "value": "sectigo.com"})

    def test_address_record_is_updated_when_it_points_elsewhere_or_is_proxied(self):
        want = {"type": "A", "name": HOST, "content": "203.0.113.7"}
        self.assertEqual(d.plan(want, [{"id": "3", "content": "203.0.113.9"}])[:2], ("update", "3"))
        self.assertEqual(d.plan(want, [{"id": "3", "content": "203.0.113.7", "proxied": True}])[:2], ("update", "3"))
        self.assertEqual(d.plan(want, [{"id": "3", "content": "203.0.113.7", "proxied": False}])[0], "none")

    def test_priority_is_sent_for_mail_records(self):
        want = {"type": "MX", "name": "send.relay.example.com", "content": "feedback-smtp.example.net", "priority": 10}
        self.assertEqual(d.plan(want, [])[2]["priority"], 10)


class Alignment(unittest.TestCase):
    def test_resend_records_under_the_host_align(self):
        records = [
            {"record": "DKIM", "type": "TXT", "name": "resend._domainkey.relay", "value": "p=abc"},
            {"record": "SPF", "type": "MX", "name": "send.relay", "value": "feedback-smtp.example.net", "priority": 10},
            {"record": "SPF", "type": "TXT", "name": "send.relay", "value": "v=spf1 include:example.net ~all"},
        ]
        self.assertEqual(d.alignment_problems(records, HOST, ZONE), [])

    def test_dkim_outside_the_host_is_reported(self):
        records = [{"record": "DKIM", "type": "TXT", "name": "resend._domainkey.other", "value": "p=abc"}]
        self.assertEqual(len(d.alignment_problems(records, HOST, ZONE)), 1)

    def test_missing_dkim_is_reported(self):
        self.assertEqual(len(d.alignment_problems([], HOST, ZONE)), 1)


class Reminder(unittest.TestCase):
    def test_verified_domain_with_the_admin_key_gets_the_reminder(self):
        self.assertIn("RESEND_ADMIN_KEY", d.admin_key_reminder("verified"))
        self.assertIn(".env", d.admin_key_reminder("verified"))

    def test_unverified_domain_gets_none(self):
        self.assertEqual(d.admin_key_reminder("pending"), "")
        self.assertEqual(d.admin_key_reminder(None), "")


if __name__ == "__main__":
    unittest.main()
