#!/usr/bin/python3 -I
"""Latchkey sentinel: watches the relay's server for signs of intrusion.

Every finding is written to Google Cloud Logging (log "latchkey-sentinel"), off the server, where
an intruder who becomes root can't take it back; alert policies made by deploy/harden.sh email
the owner for every WARNING. A heartbeat every 10 minutes lets an alert fire when the sentinel
goes silent (stopped, killed, or the server down).

What it watches:
- audit events (deploy/server/host/audit.rules, keys "lk_..."): writes to the relay's key folder,
  sshd, sudoers, accounts, cron, systemd units, Docker's settings, loader preloads, PAM, apt
  sources; kernel modules; every root command of a logged-in user. A change made in the owner's
  own SSH session (by login uid) or by a package update is recorded quietly; anything else is a
  WARNING.
- SSH logins and sudo (the journal): anyone but the owner's OS Login accounts is a WARNING.
- Docker (docker events): a command run inside a container other than its health check and the
  few the deploy and backups run; a container that isn't one of the three known ones; a
  container started privileged, on the host's network or process space, or with mounts other
  than its own; out-of-memory kills and failed health checks.
- every minute: listening ports not on the list, processes in a container other than its own
  program, programs running from /tmp, /dev/shm or deleted-in-place files outside /usr, and
  kernel modules from outside the installed kernel.
- daily: `dpkg --verify` (a package's program changed on disk), new set-user-ID programs, and
  /etc/ld.so.preload.

Standard library only. Tested by deploy/tests/test_sentinel.py (the pure functions).
"""

import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

CONFIG_PATH = "/etc/latchkey-sentinel.json"
STATE_DIR = "/var/lib/latchkey-sentinel"
LOG_NAME = "latchkey-sentinel"
AUDIT_LOG = "/var/log/audit/audit.log"
METADATA = "http://metadata.google.internal/computeMetadata/v1/"
HEARTBEAT_SECONDS = 600
PERIODIC_SECONDS = 60
DAILY_SECONDS = 86400
REPEAT_SECONDS = 3600  # the same finding is reported at most once an hour

INFO, NOTICE, WARNING = "INFO", "NOTICE", "WARNING"
AUID_UNSET = "4294967295"

# --- What normal looks like (pure data and functions; tested) ---

# Listening sockets that belong here: SSH, the web ports (Caddy, through Docker), the local DNS
# resolver, chrony's local port, and DHCP on the VM's interface.
ALLOWED_LISTEN = [
    ("tcp", r"(0\.0\.0\.0|\[::\]|\*):22"),
    ("tcp", r"(0\.0\.0\.0|\[::\]|\*):(80|443)"),
    ("udp", r"(0\.0\.0\.0|\[::\]|\*):443"),
    ("tcp", r"127\.0\.0\.5[34](%lo)?:53"),
    ("udp", r"127\.0\.0\.5[34](%lo)?:53"),
    ("udp", r"(127\.0\.0\.1|\[::1\]):323"),
    ("udp", r"[0-9.]+%[a-z0-9]+:68"),
]

# The three containers that belong here, the programs each may run, and the mounts each may have
# (host path prefixes and named volumes).
CONTAINERS = {
    "latchkey-relay": {
        "programs": {"relay"},
        "mounts": {"/opt/latchkey/keys/relay", "volume:latchkey_latchkey-data"},
    },
    "caddy": {
        "programs": {"caddy"},
        "mounts": {
            "/opt/reverse-proxy/Caddyfile",
            "volume:hackernews_caddy-data",
            "volume:hackernews_caddy-config",
        },
    },
    "hackernews-app-1": {
        "programs": {"node", "MainThread"},
        "mounts": {"volume:hackernews_sqlite-data"},
    },
    # latchkey-update-apps checks a new Caddy version against the Caddyfile in this one first.
    "caddy-check": {
        "programs": {"caddy"},
        "mounts": {"/opt/reverse-proxy/Caddyfile"},
    },
}

# Commands the deploy (deploy/deploy.sh, deploy/lib.sh) and the hackernews backup run inside
# containers, besides each container's own health check.
EXPECTED_EXEC = {
    "caddy": [r"caddy (validate|reload) --config /etc/caddy/Caddyfile"],
    "hackernews-app-1": [r"sqlite3 /data/hackernews\.db \.backup '/tmp/hackernews-backup\.db'"],
}

# Programs that keep the system running and may write watched files outside anyone's session,
# by the path the kernel resolved (a process can name itself anything; it can't fake its exe).
SYSTEM_WRITERS = {
    "/usr/bin/google_guest_agent", "/usr/bin/google_guest_compat_manager", "/usr/lib/systemd/systemd",
    "/usr/bin/systemd-sysusers", "/usr/bin/dockerd", "/usr/bin/containerd",
    "/usr/sbin/sshd", "/usr/sbin/logrotate", "/usr/sbin/chronyd", "/usr/sbin/cron",
}
# The package tools; while one runs, writes it causes (its maintainer scripts are shells) are an update.
PACKAGE_EXES = {"/usr/bin/dpkg", "/usr/bin/apt", "/usr/bin/apt-get"}
# Places where no write is ever explained away by an update or a system program: only the
# owner's own session is quiet there (a package almost never touches them; a false alarm on one
# is cheap, a missed intrusion isn't).
NEVER_QUIET = {"lk_relay", "lk_caddy", "lk_apps", "lk_sudoers", "lk_ssh_keys", "lk_preload", "lk_audit",
               "lk_docker", "lk_sshd"}
# Each known container's image, by name (a container may take a known name; not a known image).
IMAGES = {
    "latchkey-relay": r"latchkey-relay:[0-9a-f]{7,40}",
    "caddy": r"caddy:2-alpine",
    "caddy-check": r"caddy:2-alpine",
    "hackernews-app-1": r"ghcr\.io/tonimelisma/hackernews:(latest|[0-9a-f]{7,40})",
}


def unexpected_listeners(ss_output):
    """Lines of `ss -Hltun` (Netid State Recv-Q Send-Q Local Peer ...) whose local address isn't
    allowed. Returns a sorted list of "proto address"."""
    found = set()
    for line in ss_output.splitlines():
        parts = line.split()
        if len(parts) < 5:
            continue
        proto, local = parts[0], parts[4]
        if not any(proto == p and re.fullmatch(rx, local) for p, rx in ALLOWED_LISTEN):
            found.add(f"{proto} {local}")
    return sorted(found)


def classify_exec(container, command, healthcheck):
    """Severity of a command run inside a container (docker events exec_create), or None for its
    own health check. healthcheck is the container's Healthcheck.Test list."""
    if healthcheck and healthcheck[0] in ("CMD", "CMD-SHELL"):
        own = " ".join(healthcheck[1:])
        if command.strip() == own.strip():
            return None
    for rx in EXPECTED_EXEC.get(container, []):
        if re.fullmatch(rx, command.strip()):
            return NOTICE
    return WARNING


def unexpected_programs(container, programs):
    """Programs (ps comm names) in a known container other than its own."""
    known = CONTAINERS.get(container)
    if known is None:
        return sorted(set(programs))
    return sorted(set(p for p in programs if p not in known["programs"]))


def container_problems(name, inspect):
    """What is wrong with a started container, from `docker inspect` (one object): unknown name,
    privileged, the host's namespaces, extra capabilities, or mounts that aren't its own."""
    problems = []
    known = CONTAINERS.get(name)
    image = (inspect.get("Config") or {}).get("Image", "?")
    host = inspect.get("HostConfig", {})
    if known is None:
        problems.append(f"unknown container {name} (image {image})")
    elif not re.fullmatch(IMAGES[name], image):
        problems.append(f"image {image} isn't {name}'s")
    if name == "caddy-check" and (host.get("NetworkMode") != "none" or not host.get("ReadonlyRootfs")):
        problems.append("caddy-check with a network or a writable filesystem")
    if host.get("Privileged"):
        problems.append("privileged")
    for mode in ("PidMode", "NetworkMode", "IpcMode", "UTSMode", "UsernsMode"):
        if host.get(mode) == "host":
            problems.append(f"{mode} host")
    if host.get("CapAdd"):
        extra = [c for c in host["CapAdd"] if not (name == "caddy" and c in ("NET_BIND_SERVICE", "CAP_NET_BIND_SERVICE"))]
        if extra:
            problems.append("added capabilities " + ",".join(extra))
    for dev in host.get("Devices") or []:
        problems.append("device " + str(dev.get("PathOnHost")))
    for m in inspect.get("Mounts") or []:
        if m.get("Type") == "volume":
            key = "volume:" + str(m.get("Name"))
        else:
            key = str(m.get("Source"))
        if known is None or key not in known["mounts"]:
            problems.append(f"mount {key} at {m.get('Destination')}")
    return problems


def parse_audit_line(line):
    """One audit.log line to (type, serial, fields). Hex-encoded values (names with spaces or
    unusual characters) are decoded."""
    m = re.match(r"type=(\S+) msg=audit\((\d+\.\d+):(\d+)\):\s?(.*)", line)
    if not m:
        return None
    kind, serial, rest = m.group(1), m.group(3), m.group(4)
    fields = {}
    for k, v in re.findall(r'(\w+)=("[^"]*"|\S+)', rest):
        if v.startswith('"'):
            v = v[1:-1]
        elif k in ("name", "exe", "comm", "proctitle", "key", "cwd") and re.fullmatch(r"(?:[0-9A-F]{2})+", v):
            try:
                v = bytes.fromhex(v).decode("utf-8", "replace").replace("\x00", " ")
            except ValueError:
                pass
        fields.setdefault(k, v)
        if kind == "PATH" and k == "name":
            fields.setdefault("names", []).append(v)
    return kind, serial, fields


# init_module loads a module from memory, with no file to check (finit_module, which modprobe
# uses, loads one from a file): x86-64 and 32-bit syscall numbers.
INIT_MODULE_FROM_MEMORY = {("c000003e", "175"), ("40000003", "128")}


def classify_audit(event, owner_uids, from_dpkg):
    """Severity of one grouped audit event (dict with key, auid, exe, arch, syscall). from_dpkg:
    the process that made it was started by dpkg (checked from its own parents when the event
    came, never from whatever else is running). The owner's sessions are quiet; outside
    NEVER_QUIET, dpkg's writes and system programs (by exe) too; anything else is a WARNING."""
    key = event.get("key", "")
    auid = event.get("auid", AUID_UNSET)
    exe = event.get("exe", "")
    if auid in owner_uids:
        return INFO if key == "lk_root_exec" else NOTICE
    if auid not in (AUID_UNSET, "unset", "-1"):
        return WARNING  # a session of someone else: a local account or an unknown OS Login user
    if key == "lk_root_exec":
        return INFO
    if key == "lk_modules":
        if (event.get("arch"), event.get("syscall")) in INIT_MODULE_FROM_MEMORY:
            return WARNING
        return NOTICE  # Docker loads netfilter modules; check_periodic judges every loaded module
    if key in NEVER_QUIET:
        return WARNING
    if from_dpkg or exe in PACKAGE_EXES or exe in SYSTEM_WRITERS:
        return NOTICE
    return WARNING


def started_by_dpkg(ppid, exe_of=None, parent_of=None):
    """The process ppid, or one of its parents, is dpkg (by exe). Walks /proc; a parent that's
    gone counts as not dpkg, so an unexplained write stays a WARNING."""
    exe_of = exe_of or (lambda p: os.readlink(f"/proc/{p}/exe"))
    parent_of = parent_of or _parent
    pid, seen = str(ppid or ""), 0
    while pid.isdigit() and pid not in ("0", "1") and seen < 16:
        try:
            if exe_of(pid) in PACKAGE_EXES:
                return True
            pid = parent_of(pid)
        except OSError:
            return False
        seen += 1
    return False


def _parent(pid):
    with open(f"/proc/{pid}/stat") as f:
        return f.read().rsplit(")", 1)[1].split()[1]


def module_problem(path, taint, release, loaded_src="", file_src=""):
    """Why a loaded module is suspect, or None: its file (resolved, links followed) isn't in the
    running kernel's own module tree or can't be found; the kernel marks it out-of-tree (O),
    unsigned (E) or forced (F); or what's loaded isn't what that file holds (srcversion)."""
    if not path:
        return "its file can't be found"
    if not re.match(r"/(usr/)?lib/modules/" + re.escape(release) + r"/kernel/", path):
        return f"from outside the kernel's own ({path})"
    bad = set(taint) & set("OEF")
    if bad:
        return "the kernel marks it " + ",".join(sorted(bad))
    if loaded_src and file_src and loaded_src != file_src:
        return f"what's loaded isn't its file ({path})"
    return None


SSH_ACCEPTED = re.compile(r"Accepted (\S+) for (\S+) from (\S+) port \d+")


def classify_journal(identifier, message, owner_users):
    """(severity, event, detail) for an sshd or sudo journal message, or None."""
    if identifier.startswith("sshd"):
        m = SSH_ACCEPTED.search(message)
        if not m:
            return None
        method, user, addr = m.groups()
        sev = NOTICE if user in owner_users else WARNING
        return sev, "ssh_login", {"user": user, "from": addr, "method": method}
    if identifier in ("sudo", "su"):
        m = re.match(r"\s*(\S+) : ", message)
        user = m.group(1) if m else "?"
        if "COMMAND=" not in message and identifier == "sudo":
            return None
        sev = INFO if user in owner_users else WARNING
        return sev, identifier, {"user": user, "message": message[:500]}
    return None


def suspicious_exe(path):
    """A running program's /proc/<pid>/exe target that hints at malware: run from a temp or
    shared-memory folder, from memory, or deleted (outside /usr, where upgrades replace files)."""
    if path.startswith("memfd:") or path.startswith("/memfd:"):
        return True
    for prefix in ("/tmp/", "/var/tmp/", "/dev/shm/", "/run/user/", "/home/", "/root/"):
        if path.startswith(prefix):
            return True
    if path.endswith(" (deleted)") and not path.startswith(("/usr/", "/opt/containerd/")):
        return True
    return False


def dpkg_findings(output):
    """`dpkg --verify` output to (changed programs and libraries, changed config files)."""
    changed, conf = [], []
    for line in output.splitlines():
        m = re.match(r"(\S{9}) +(c?) *(/\S.*)$", line)
        if not m:
            continue
        flags, is_conf, path = m.groups()
        if flags[2] != "5":
            continue  # only a changed checksum counts; dpkg can't check the rest reliably
        (conf if is_conf == "c" else changed).append(path)
    return changed, conf


# --- Writing to Cloud Logging ---


class Shipper:
    """Batches entries and writes them with the VM's own service account (logging.write). What
    can't be sent is kept (in memory and a spool file) and sent later."""

    def __init__(self, project, instance_id, zone):
        self.project, self.instance_id, self.zone = project, instance_id, zone
        self.pending, self.lock = [], threading.Lock()
        self.token, self.token_expiry = None, 0
        self.spool = os.path.join(STATE_DIR, "spool.jsonl")
        self.recent = {}
        try:
            with open(self.spool) as f:
                self.pending = [json.loads(line) for line in f if line.strip()][-5000:]
        except (OSError, ValueError):
            pass

    def emit(self, severity, event, message, repeat_key=None, **detail):
        if repeat_key is not None:
            now = time.time()
            last = self.recent.get(repeat_key, 0)
            if now - last < REPEAT_SECONDS:
                return
            self.recent[repeat_key] = now
        payload = {"event": event, "message": message}
        payload.update(detail)
        entry = {
            "logName": f"projects/{self.project}/logs/{LOG_NAME}",
            "resource": {"type": "gce_instance", "labels": {
                "project_id": self.project, "instance_id": self.instance_id, "zone": self.zone}},
            "severity": severity,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "jsonPayload": payload,
        }
        print(f"{severity} {event}: {message}", flush=True)
        with self.lock:
            self.pending.append(entry)
            del self.pending[:-5000]

    def _token(self):
        if self.token and time.time() < self.token_expiry - 60:
            return self.token
        req = urllib.request.Request(METADATA + "instance/service-accounts/default/token",
                                     headers={"Metadata-Flavor": "Google"})
        with urllib.request.urlopen(req, timeout=10) as r:
            d = json.load(r)
        self.token, self.token_expiry = d["access_token"], time.time() + int(d.get("expires_in", 300))
        return self.token

    def flush(self):
        with self.lock:
            batch, self.pending = self.pending[:500], self.pending[500:]
        if not batch:
            return True
        try:
            body = json.dumps({"entries": batch, "partialSuccess": True}).encode()
            req = urllib.request.Request("https://logging.googleapis.com/v2/entries:write", data=body,
                                         headers={"Authorization": "Bearer " + self._token(),
                                                  "Content-Type": "application/json"})
            urllib.request.urlopen(req, timeout=20).close()
            ok = True
        except (urllib.error.URLError, OSError, ValueError, KeyError) as e:
            print(f"cloud logging write failed, kept for later: {e}", flush=True)
            with self.lock:
                self.pending[:0] = batch
                del self.pending[:-5000]
            ok = False
        self._save()
        return ok

    def _save(self):
        with self.lock:
            data = "".join(json.dumps(e) + "\n" for e in self.pending)
        tmp = self.spool + ".new"
        try:
            with open(tmp, "w") as f:
                f.write(data)
            os.replace(tmp, self.spool)
        except OSError:
            pass


# --- Watchers ---


def read_text(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def run(cmd, timeout=120):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return ""




def follow(cmd, handle, out, name):
    """Runs a following command (journalctl -f, docker events) forever, restarting it."""
    while True:
        try:
            p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            for line in p.stdout:
                try:
                    handle(line)
                except Exception as e:  # noqa: BLE001 - a bad line must not stop the watcher
                    out.emit(NOTICE, "sentinel_error", f"{name}: {e}", repeat_key=("err", name))
            p.wait()
        except OSError as e:
            out.emit(WARNING, "sentinel_error", f"{name} could not run: {e}", repeat_key=("err", name))
        time.sleep(5)


def watch_audit(out, owner_uids):
    """Follows audit.log (by inode, across rotation), groups records by event serial."""
    groups, f, inode = {}, None, None
    while True:
        try:
            st = os.stat(AUDIT_LOG)
            if f is None or st.st_ino != inode:
                if f:
                    f.close()
                f = open(AUDIT_LOG, errors="replace")
                if inode is None:
                    f.seek(0, os.SEEK_END)
                inode = st.st_ino
            line = f.readline()
        except OSError:
            time.sleep(5)
            continue
        if not line:
            for serial in list(groups):
                ev = groups.pop(serial)
                report_audit(out, ev, owner_uids)
            time.sleep(1)
            continue
        parsed = parse_audit_line(line)
        if not parsed:
            continue
        kind, serial, fields = parsed
        if kind in ("CONFIG_CHANGE", "DAEMON_END", "DAEMON_ABORT") and fields.get("auid") not in owner_uids:
            out.emit(WARNING, "audit_config", f"audit {kind}: {line.strip()[:300]}")
            continue
        ev = groups.setdefault(serial, {})
        if kind == "SYSCALL":
            for k in ("key", "auid", "uid", "exe", "comm", "success", "pid", "ppid", "tty", "arch", "syscall"):
                if k in fields:
                    ev[k] = fields[k]
        elif kind == "PATH":
            ev.setdefault("paths", []).extend(fields.get("names", []))
        elif kind == "PROCTITLE":
            ev["command"] = fields.get("proctitle", "")[:500]
        elif kind == "EXECVE":
            args = [fields[k] for k in sorted((k for k in fields if re.fullmatch(r"a\d+", k)), key=lambda k: int(k[1:]))]
            ev["command"] = " ".join(args)[:500]
        if len(groups) > 200:
            for s in sorted(groups, key=int)[:-50]:
                report_audit(out, groups.pop(s), owner_uids)


def report_audit(out, ev, owner_uids):
    key = ev.get("key", "")
    if not key.startswith("lk_"):
        return
    sev = classify_audit(ev, owner_uids, key != "lk_root_exec" and started_by_dpkg(ev.get("ppid")))
    what = ev.get("command") or ev.get("exe", "?")
    paths = [p for p in ev.get("paths", []) if p not in ("(null)",)]
    msg = f"{key[3:]}: {ev.get('comm', '?')} (login uid {ev.get('auid', '?')})" + (f" on {', '.join(paths[:5])}" if paths else "")
    out.emit(sev, "audit", msg, key=key, auid=ev.get("auid"), uid=ev.get("uid"), exe=ev.get("exe"),
             command=what, paths=paths[:20])


def watch_journal(out, owner_users):
    def handle(line):
        d = json.loads(line)
        ident = d.get("SYSLOG_IDENTIFIER", "")
        msg = d.get("MESSAGE", "")
        if not isinstance(msg, str):
            return
        r = classify_journal(ident, msg, owner_users)
        if r:
            sev, event, detail = r
            out.emit(sev, event, f"{ident}: {msg[:300]}", **detail)
    follow(["journalctl", "-f", "-n", "0", "-o", "json", "SYSLOG_IDENTIFIER=sshd",
            "SYSLOG_IDENTIFIER=sshd-session", "SYSLOG_IDENTIFIER=sudo", "SYSLOG_IDENTIFIER=su"],
           handle, out, "journal")


def inspect(cid):
    try:
        return json.loads(run(["docker", "inspect", cid], timeout=20))[0]
    except (ValueError, IndexError):
        return {}


def watch_docker(out):
    health = {}

    def handle(line):
        d = json.loads(line)
        kind, action = d.get("Type"), d.get("Action", "")
        attrs = (d.get("Actor") or {}).get("Attributes") or {}
        name = attrs.get("name", "?")
        cid = (d.get("Actor") or {}).get("ID", "")
        if kind == "container" and action.startswith("exec_create"):
            command = action.split(": ", 1)[1] if ": " in action else ""
            if cid not in health:
                health[cid] = ((inspect(cid).get("Config") or {}).get("Healthcheck") or {}).get("Test") or []
            sev = classify_exec(name, command, health[cid])
            if sev:
                out.emit(sev, "docker_exec", f"command run inside {name}: {command[:300]}", container=name, command=command[:1000])
        elif kind == "container" and action == "start":
            info = inspect(cid)
            problems = container_problems(name, info)
            if problems:
                out.emit(WARNING, "docker_container", f"container {name} started: {'; '.join(problems)}",
                         container=name, image=(info.get("Config") or {}).get("Image"), problems=problems)
            else:
                out.emit(NOTICE, "docker_container", f"container {name} started", container=name,
                         image=(info.get("Config") or {}).get("Image"))
        elif kind == "container" and action in ("oom", "health_status: unhealthy"):
            out.emit(WARNING, "docker_health", f"container {name}: {action}", container=name)
        elif kind == "container" and action == "die":
            out.emit(NOTICE, "docker_container", f"container {name} stopped (exit {attrs.get('exitCode')})", container=name)
        elif kind in ("image", "network", "volume") and not action.startswith("mount") and action != "unmount":
            out.emit(INFO, "docker_" + kind, f"{kind} {action} {name if name != '?' else cid[:20]}")

    follow(["docker", "events", "--format", "{{json .}}"], handle, out, "docker events")


def check_periodic(out):
    for item in unexpected_listeners(run(["ss", "-Hltun"])):
        out.emit(WARNING, "listener", f"something new is listening: {item}", repeat_key=("listen", item), socket=item)
    names = run(["docker", "ps", "--format", "{{.Names}}"]).split()
    for name in names:
        top = run(["docker", "top", name, "-eo", "pid,comm"], timeout=20).splitlines()[1:]
        progs = [line.split(None, 1)[1].strip() for line in top if len(line.split(None, 1)) == 2]
        for prog in unexpected_programs(name, progs):
            out.emit(WARNING, "container_process", f"{prog} is running inside {name}", repeat_key=("proc", name, prog), container=name, program=prog)
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            exe = os.readlink(f"/proc/{pid}/exe")
        except OSError:
            continue
        if suspicious_exe(exe):
            out.emit(WARNING, "process", f"process {pid} runs {exe}", repeat_key=("exe", exe), pid=pid, exe=exe)
    release = os.uname().release
    try:
        with open("/proc/modules") as f:
            mods = [line.split()[0] for line in f]
    except OSError:
        mods = []
    for mod in mods:
        path = run(["modinfo", "-k", release, "-n", mod], timeout=10).strip()
        path = os.path.realpath(path) if path.startswith("/") else ""
        taint = read_text(f"/sys/module/{mod}/taint")
        loaded_src = read_text(f"/sys/module/{mod}/srcversion")
        file_src = run(["modinfo", "-F", "srcversion", path], timeout=10).strip() if path and loaded_src else ""
        problem = module_problem(path, taint, release, loaded_src, file_src)
        if problem:
            out.emit(WARNING, "kernel_module", f"kernel module {mod}: {problem}", repeat_key=("mod", mod), module=mod, path=path, taint=taint)


def check_daily(out):
    changed, conf = dpkg_findings(run(["nice", "-n", "19", "ionice", "-c", "3", "dpkg", "--verify"], timeout=3600))
    if changed:
        out.emit(WARNING, "dpkg_verify", f"{len(changed)} installed program files differ from their packages: {', '.join(changed[:10])}", files=changed[:200])
    if conf:
        out.emit(NOTICE, "dpkg_verify", f"{len(conf)} package config files were changed: {', '.join(conf[:10])}", files=conf[:200])
    suid = sorted(run(["nice", "-n", "19", "find", "/", "-xdev", "-type", "f", "-perm", "-4000"], timeout=3600).split())
    base = os.path.join(STATE_DIR, "suid.txt")
    try:
        with open(base) as f:
            old = set(f.read().split())
        new = [p for p in suid if p not in old]
        if new:
            out.emit(WARNING, "suid", f"new set-user-ID programs: {', '.join(new[:10])}", files=new)
    except OSError:
        pass
    with open(base, "w") as f:
        f.write("\n".join(suid) + "\n")
    if os.path.exists("/etc/ld.so.preload"):
        out.emit(WARNING, "preload", "/etc/ld.so.preload exists (it injects a library into every program)", repeat_key=("preload",))


def metadata(path):
    req = urllib.request.Request(METADATA + path, headers={"Metadata-Flavor": "Google"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.read().decode()


def stop_reason(state, nologin, planned_age):
    """Why the sentinel is being stopped, when that's expected: the server shutting down (systemd
    says so, or has created /run/nologin, which it does while stopping), or a restart setup.sh
    announced in the last two minutes. None otherwise: a stop worth a WARNING."""
    if state == "stopping" or nologin:
        return "the server is shutting down"
    if planned_age is not None and 0 <= planned_age < 120:
        return "restarted by setup.sh"
    return None


def file_age(path):
    try:
        return time.time() - os.stat(path).st_mtime
    except OSError:
        return None


class Printer:
    """For --check: findings printed, nothing sent."""

    def emit(self, severity, event, message, repeat_key=None, **detail):
        print(f"{severity} {event}: {message}", flush=True)


def main():
    if "--check" in sys.argv:
        # What the periodic checks would report now, sent nowhere: for trying the rules out.
        check_periodic(Printer())
        print("check done", flush=True)
        return
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    with open(CONFIG_PATH) as f:
        cfg = json.load(f)
    owner_uids = set(str(u) for u in cfg.get("owner_uids", []))
    owner_users = set(cfg.get("owner_users", []))
    out = Shipper(metadata("project/project-id"), metadata("instance/id"), metadata("instance/zone").rsplit("/", 1)[-1])
    if "--test" in sys.argv:
        out.emit(WARNING, "test", "Test alert from the Latchkey sentinel: the alert path works. Nothing is wrong.")
        sys.exit(0 if out.flush() else 1)

    def stop(_sig, _frame):
        state = run(["systemctl", "is-system-running"]).strip()
        why = stop_reason(state, os.path.exists("/run/nologin"), file_age("/run/latchkey-sentinel.planned"))
        sev = NOTICE if why else WARNING
        out.emit(sev, "sentinel_stop", f"sentinel stopping ({why or 'not by a shutdown or setup.sh'}; system {state or 'unknown'})")
        out.flush()
        sys.exit(0)

    signal.signal(signal.SIGTERM, stop)
    out.emit(NOTICE, "sentinel_start", "sentinel started", owner_users=sorted(owner_users))
    for target, args in ((watch_audit, (out, owner_uids)), (watch_journal, (out, owner_users)), (watch_docker, (out,))):
        threading.Thread(target=target, args=args, daemon=True).start()
    last_beat = last_periodic = 0.0
    daily_stamp = os.path.join(STATE_DIR, "daily")
    while True:
        now = time.time()
        if now - last_beat >= HEARTBEAT_SECONDS:
            out.emit(INFO, "heartbeat", "sentinel running", uptime=run(["uptime", "-p"]).strip())
            last_beat = now
        if now - last_periodic >= PERIODIC_SECONDS:
            check_periodic(out)
            last_periodic = now
        try:
            due = now - os.stat(daily_stamp).st_mtime >= DAILY_SECONDS
        except OSError:
            due = True
        if due:
            with open(daily_stamp, "w"):
                pass
            threading.Thread(target=check_daily, args=(out,), daemon=True).start()
        out.flush()
        time.sleep(5)


if __name__ == "__main__":
    main()
