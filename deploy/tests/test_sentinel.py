"""Tests for the sentinel's decisions (deploy/server/host/sentinel.py): what counts as normal on
the relay's server and what is reported as a WARNING. Run: make -C relay script-tests."""

import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("sentinel", os.path.join(HERE, "..", "server", "host", "sentinel.py"))
sentinel = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sentinel)

OWNER_UIDS = {"34248051"}
OWNER_USERS = {"owner_example_com"}


class Listeners(unittest.TestCase):
    NORMAL = """\
udp UNCONN 0 0 127.0.0.1:323 0.0.0.0:*
udp UNCONN 0 0 127.0.0.54:53 0.0.0.0:*
udp UNCONN 0 0 127.0.0.53%lo:53 0.0.0.0:*
udp UNCONN 0 0 10.128.0.2%ens4:68 0.0.0.0:*
udp UNCONN 0 0 [::1]:323 [::]:*
tcp LISTEN 0 4096 0.0.0.0:22 0.0.0.0:*
tcp LISTEN 0 4096 0.0.0.0:80 0.0.0.0:*
tcp LISTEN 0 4096 127.0.0.53%lo:53 0.0.0.0:*
tcp LISTEN 0 4096 0.0.0.0:443 0.0.0.0:*
tcp LISTEN 0 4096 [::]:22 [::]:*
tcp LISTEN 0 4096 [::]:443 [::]:*
"""

    def test_the_servers_own_ports_are_normal(self):
        self.assertEqual(sentinel.unexpected_listeners(self.NORMAL), [])

    def test_a_new_port_is_reported(self):
        out = sentinel.unexpected_listeners(self.NORMAL + "tcp LISTEN 0 128 0.0.0.0:4444 0.0.0.0:*\n")
        self.assertEqual(out, ["tcp 0.0.0.0:4444"])

    def test_a_public_dns_or_time_port_is_reported(self):
        out = sentinel.unexpected_listeners("udp UNCONN 0 0 0.0.0.0:53 0.0.0.0:*\nudp UNCONN 0 0 0.0.0.0:323 0.0.0.0:*\n")
        self.assertEqual(out, ["udp 0.0.0.0:323", "udp 0.0.0.0:53"])

    def test_caddys_admin_port_on_the_host_is_reported(self):
        self.assertEqual(sentinel.unexpected_listeners("tcp LISTEN 0 4096 0.0.0.0:2019 0.0.0.0:*\n"), ["tcp 0.0.0.0:2019"])


class Exec(unittest.TestCase):
    HEALTH = ["CMD", "wget", "--spider", "-q", "http://localhost:3000/api/v1/stories?timespan=Day&limit=1"]

    def test_a_health_check_is_ignored(self):
        cmd = "wget --spider -q http://localhost:3000/api/v1/stories?timespan=Day&limit=1"
        self.assertIsNone(sentinel.classify_exec("hackernews-app-1", cmd, self.HEALTH))
        self.assertIsNone(sentinel.classify_exec("latchkey-relay", "/relay healthcheck", ["CMD", "/relay", "healthcheck"]))

    def test_the_deploys_caddy_commands_are_quiet(self):
        for cmd in ("caddy reload --config /etc/caddy/Caddyfile", "caddy validate --config /etc/caddy/Caddyfile"):
            self.assertEqual(sentinel.classify_exec("caddy", cmd, []), sentinel.NOTICE)

    def test_the_backup_is_quiet(self):
        cmd = "sqlite3 /data/hackernews.db .backup '/tmp/hackernews-backup.db'"
        self.assertEqual(sentinel.classify_exec("hackernews-app-1", cmd, self.HEALTH), sentinel.NOTICE)

    def test_a_shell_is_a_warning(self):
        self.assertEqual(sentinel.classify_exec("hackernews-app-1", "sh", self.HEALTH), sentinel.WARNING)
        self.assertEqual(sentinel.classify_exec("caddy", "sh -c id", []), sentinel.WARNING)

    def test_a_command_in_the_relay_is_a_warning(self):
        # Operator commands are rare and worth an email; anything else there is an intrusion.
        self.assertEqual(sentinel.classify_exec("latchkey-relay", "/relay account list", ["CMD", "/relay", "healthcheck"]), sentinel.WARNING)

    def test_a_caddy_command_with_more_is_a_warning(self):
        self.assertEqual(sentinel.classify_exec("caddy", "caddy reload --config /etc/caddy/Caddyfile; sh", []), sentinel.WARNING)


class Containers(unittest.TestCase):
    def relay(self, **host):
        return {
            "Config": {"Image": "latchkey-relay:abc"},
            "HostConfig": {"Privileged": False, "NetworkMode": "latchkey-front", "PidMode": "", **host},
            "Mounts": [
                {"Type": "volume", "Name": "latchkey_latchkey-data", "Destination": "/data"},
                {"Type": "bind", "Source": "/opt/latchkey/keys/relay", "Destination": "/keys"},
            ],
        }

    def test_the_relay_as_deployed_is_fine(self):
        self.assertEqual(sentinel.container_problems("latchkey-relay", self.relay()), [])

    def test_caddy_may_bind_web_ports(self):
        info = {"HostConfig": {"CapAdd": ["NET_BIND_SERVICE"]}, "Mounts": [
            {"Type": "bind", "Source": "/opt/reverse-proxy/Caddyfile", "Destination": "/etc/caddy/Caddyfile"},
            {"Type": "volume", "Name": "hackernews_caddy-data", "Destination": "/data"}]}
        self.assertEqual(sentinel.container_problems("caddy", info), [])

    def test_privileged_or_host_namespaces_are_reported(self):
        self.assertIn("privileged", sentinel.container_problems("latchkey-relay", self.relay(Privileged=True)))
        self.assertIn("PidMode host", sentinel.container_problems("latchkey-relay", self.relay(PidMode="host")))
        self.assertIn("NetworkMode host", sentinel.container_problems("latchkey-relay", self.relay(NetworkMode="host")))

    def test_an_extra_capability_is_reported(self):
        self.assertEqual(sentinel.container_problems("latchkey-relay", self.relay(CapAdd=["SYS_ADMIN"])), ["added capabilities SYS_ADMIN"])

    def test_a_mount_of_the_host_is_reported(self):
        info = self.relay()
        info["Mounts"].append({"Type": "bind", "Source": "/", "Destination": "/host"})
        self.assertEqual(sentinel.container_problems("latchkey-relay", info), ["mount / at /host"])

    def test_the_relays_keys_in_another_container_are_reported(self):
        info = {"HostConfig": {}, "Mounts": [{"Type": "bind", "Source": "/opt/latchkey/keys/relay", "Destination": "/k"}]}
        self.assertEqual(sentinel.container_problems("hackernews-app-1", info), ["mount /opt/latchkey/keys/relay at /k"])

    def test_an_unknown_container_is_reported(self):
        out = sentinel.container_problems("miner", {"Config": {"Image": "x/y"}, "HostConfig": {}, "Mounts": []})
        self.assertEqual(out, ["unknown container miner (image x/y)"])

    def test_programs_in_a_container(self):
        self.assertEqual(sentinel.unexpected_programs("latchkey-relay", ["relay"]), [])
        self.assertEqual(sentinel.unexpected_programs("latchkey-relay", ["relay", "sh", "nc"]), ["nc", "sh"])
        self.assertEqual(sentinel.unexpected_programs("hackernews-app-1", ["node", "MainThread"]), [])
        self.assertEqual(sentinel.unexpected_programs("hackernews-app-1", ["node", "xmrig"]), ["xmrig"])


class Audit(unittest.TestCase):
    def test_parse_a_watch_event(self):
        line = ('type=SYSCALL msg=audit(1763750000.123:4567): arch=c000003e syscall=257 success=yes exit=3 '
                'ppid=1 pid=99 auid=4294967295 uid=0 gid=0 tty=(none) ses=4294967295 comm="sh" '
                'exe="/usr/bin/dash" key="lk_sudoers"')
        kind, serial, fields = sentinel.parse_audit_line(line)
        self.assertEqual((kind, serial), ("SYSCALL", "4567"))
        self.assertEqual(fields["key"], "lk_sudoers")
        self.assertEqual(fields["auid"], "4294967295")
        self.assertEqual(fields["exe"], "/usr/bin/dash")

    def test_hex_names_are_decoded(self):
        line = 'type=PATH msg=audit(1763750000.123:4567): item=0 name=2F746D702F6120622F63 inode=5'
        _, _, fields = sentinel.parse_audit_line(line)
        self.assertEqual(fields["names"], ["/tmp/a b/c"])

    def test_the_owners_session_is_quiet(self):
        ev = {"key": "lk_sudoers", "auid": "34248051", "comm": "sh"}
        self.assertEqual(sentinel.classify_audit(ev, OWNER_UIDS, False), sentinel.NOTICE)
        ev = {"key": "lk_root_exec", "auid": "34248051", "comm": "docker"}
        self.assertEqual(sentinel.classify_audit(ev, OWNER_UIDS, False), sentinel.INFO)

    def test_someone_elses_session_is_a_warning(self):
        for key in ("lk_sudoers", "lk_root_exec", "lk_relay"):
            ev = {"key": key, "auid": "1001", "comm": "vi"}
            self.assertEqual(sentinel.classify_audit(ev, OWNER_UIDS, False), sentinel.WARNING)

    def test_a_package_update_is_quiet(self):
        ev = {"key": "lk_systemd", "auid": "4294967295", "comm": "sh"}
        self.assertEqual(sentinel.classify_audit(ev, OWNER_UIDS, True), sentinel.NOTICE)
        ev = {"key": "lk_apt", "auid": "4294967295", "comm": "dpkg"}
        self.assertEqual(sentinel.classify_audit(ev, OWNER_UIDS, False), sentinel.NOTICE)

    def test_a_write_from_no_session_is_a_warning(self):
        # A container escape or a hijacked service: no login uid, not a package update.
        ev = {"key": "lk_relay", "auid": "4294967295", "comm": "python3"}
        self.assertEqual(sentinel.classify_audit(ev, OWNER_UIDS, False), sentinel.WARNING)
        ev = {"key": "lk_ssh_keys", "auid": "unset", "comm": "node"}
        self.assertEqual(sentinel.classify_audit(ev, OWNER_UIDS, False), sentinel.WARNING)

    def test_googles_agent_managing_accounts_is_quiet(self):
        ev = {"key": "lk_accounts", "auid": "4294967295", "comm": "google_guest_ag"}
        self.assertEqual(sentinel.classify_audit(ev, OWNER_UIDS, False), sentinel.NOTICE)


class Journal(unittest.TestCase):
    def test_the_owners_login_is_quiet(self):
        sev, event, d = sentinel.classify_journal(
            "sshd", "Accepted publickey for owner_example_com from 35.235.244.1 port 40000 ssh2: ED25519 SHA256:x", OWNER_USERS)
        self.assertEqual((sev, event, d["user"], d["from"]), (sentinel.NOTICE, "ssh_login", "owner_example_com", "35.235.244.1"))

    def test_any_other_login_is_a_warning(self):
        sev, _, d = sentinel.classify_journal("sshd", "Accepted publickey for tonimelisma from 1.2.3.4 port 5 ssh2", OWNER_USERS)
        self.assertEqual((sev, d["user"]), (sentinel.WARNING, "tonimelisma"))

    def test_failed_attempts_are_ignored(self):
        self.assertIsNone(sentinel.classify_journal("sshd", "Invalid user admin from 1.2.3.4 port 5", OWNER_USERS))

    def test_sudo(self):
        msg = "owner_example_com : PWD=/ ; USER=root ; COMMAND=/usr/bin/docker ps"
        self.assertEqual(sentinel.classify_journal("sudo", msg, OWNER_USERS)[0], sentinel.INFO)
        msg = "ubuntu : PWD=/ ; USER=root ; COMMAND=/bin/sh"
        self.assertEqual(sentinel.classify_journal("sudo", msg, OWNER_USERS)[0], sentinel.WARNING)
        self.assertIsNone(sentinel.classify_journal("sudo", "pam_unix(sudo:session): session closed", OWNER_USERS))


class Programs(unittest.TestCase):
    def test_suspicious(self):
        for path in ("/tmp/x", "/dev/shm/.a", "/var/tmp/k", "memfd:payload (deleted)", "/home/u/miner", "/opt/thing (deleted)"):
            self.assertTrue(sentinel.suspicious_exe(path), path)

    def test_normal(self):
        for path in ("/usr/bin/dockerd", "/usr/sbin/sshd", "/usr/lib/systemd/systemd (deleted)", "/relay"):
            self.assertFalse(sentinel.suspicious_exe(path), path)


class Dpkg(unittest.TestCase):
    def test_findings(self):
        out = "??5??????   /usr/bin/sudo\n??5?????? c /etc/ssh/sshd_config\n?????????   /usr/bin/ok\nmissing     /usr/share/doc/x\n"
        self.assertEqual(sentinel.dpkg_findings(out), (["/usr/bin/sudo"], ["/etc/ssh/sshd_config"]))


class RepeatLimit(unittest.TestCase):
    def test_the_same_finding_is_sent_once_an_hour(self):
        s = sentinel.Shipper.__new__(sentinel.Shipper)
        s.project, s.instance_id, s.zone = "p", "1", "z"
        s.pending, s.recent = [], {}
        import threading
        s.lock = threading.Lock()
        import contextlib
        import io
        with contextlib.redirect_stdout(io.StringIO()):
            s.emit(sentinel.WARNING, "listener", "a", repeat_key=("listen", "x"))
            s.emit(sentinel.WARNING, "listener", "a", repeat_key=("listen", "x"))
            s.emit(sentinel.WARNING, "listener", "b", repeat_key=("listen", "y"))
        self.assertEqual([e["jsonPayload"]["message"] for e in s.pending], ["a", "b"])
        self.assertEqual(s.pending[0]["logName"], "projects/p/logs/latchkey-sentinel")
        self.assertEqual(s.pending[0]["severity"], "WARNING")


if __name__ == "__main__":
    unittest.main()
