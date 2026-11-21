#!/bin/sh
# Hardens the relay's server. Runs as root on the VM, started by deploy/harden.sh, with the other
# files of deploy/server/host (and sentinel.json, written by harden.sh) beside it. Safe to rerun:
# each step changes only what differs. The last line it prints is "REBOOT" when the server
# needs a restart for what it changed (a new kernel, Docker's settings, the locked audit rules).
# What and why: docs/threat-model.md, "The relay's server".
set -eu
cd "$(dirname "$0")"
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
reboot_needed=''
say() { printf '  - %s\n' "$*"; }

# put SRC DEST MODE: installs SRC as DEST when it differs; succeeds only when it changed DEST.
put() {
  if [ -f "$2" ] && cmp -s "$1" "$2"; then return 1; fi
  install -D -m "$3" -o root -g root "$1" "$2"
  say "installed $2"
}

# --- Packages: what the server doesn't need goes; what it can't do without is switched off ---
# Crash reports (a dump can hold a process's secrets), Ubuntu's boot-time random-seed fetch,
# LXD's on-demand installer, plain-text clients, PackageKit's install-over-D-Bus daemon, Docker's
# unused extras, the boot splash, RAID tools, and tools an intruder would use to snoop or tunnel.
REMOVE='apport apport-core-dump-handler apport-symptoms python3-apport pollinate lxd-installer
telnet inetutils-telnet ftp tnftp packagekit packagekit-tools gir1.2-packagekitglib-1.0
docker-model-plugin docker-ce-rootless-extras plymouth plymouth-theme-ubuntu-text tcpdump strace
netcat-openbsd screen byobu tmux mdadm'
# shellcheck disable=SC2086 # word splitting is the point
present=$(dpkg-query -W -f '${Package} ${db:Status-Status}\n' $REMOVE 2>/dev/null | awk '$2 == "installed" { print $1 }')
if [ -n "$present" ]; then
  # Removing them takes the ubuntu-minimal and ubuntu-standard meta-packages along; mark what
  # those held as wanted first (kernels excepted, so old ones are still cleaned up), so that
  # nothing else is ever removed as unused.
  auto=$(apt-mark showauto | grep -v '^linux-' || true)
  # shellcheck disable=SC2086
  [ -z "$auto" ] || apt-mark manual $auto >/dev/null
  # Refuse if the removal would take anything beyond this list and the two meta-packages.
  # shellcheck disable=SC2086,SC2046
  extra=$(apt-get -s purge $present | awk '/^Purg|^Remv/ { print $2 }' |
    grep -vxF -e ubuntu-minimal -e ubuntu-standard -e software-properties-common $(printf ' -e %s' $present) || true)
  if [ -n "$extra" ]; then
    echo "FAIL: removing the unneeded packages would also remove: $extra" >&2
    exit 1
  fi
  # shellcheck disable=SC2086
  apt-get -y -q purge $present >/dev/null
  say "removed $(echo "$present" | tr '\n' ' ')"
fi
for unit in google-osconfig-agent.service ua-timer.timer ubuntu-advantage.service ua-reboot-cmds.service \
  apt-news.service esm-cache.service motd-news.timer ufw.service; do
  if systemctl list-unit-files "$unit" >/dev/null 2>&1 && [ "$(systemctl is-enabled "$unit" 2>/dev/null || true)" != masked ]; then
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    systemctl mask "$unit" >/dev/null 2>&1 || true
    say "switched off $unit"
  fi
done
command -v pro >/dev/null && pro config set apt_news=false >/dev/null 2>&1 || true
# SFTP: the SSH server package needs its program installed, so it is made unrunnable instead.
if ! dpkg-statoverride --list /usr/lib/openssh/sftp-server >/dev/null 2>&1; then
  dpkg-statoverride --update --add root root 0000 /usr/lib/openssh/sftp-server
  say "SFTP switched off"
fi
# cloud-init ran once at the server's first boot; it doesn't need to read the VM's settings again.
if [ ! -f /etc/cloud/cloud-init.disabled ]; then
  touch /etc/cloud/cloud-init.disabled
  say "cloud-init switched off"
fi
if ! dpkg-query -W -f '${db:Status-Status}' auditd 2>/dev/null | grep -qx installed; then
  apt-get -y -q update >/dev/null
  apt-get -y -q install --no-install-recommends auditd >/dev/null
  say "installed auditd"
fi

# --- Settings ---
put unattended-upgrades.conf /etc/apt/apt.conf.d/52latchkey-unattended 644 || true
put modprobe.conf /etc/modprobe.d/latchkey.conf 644 || true
if put sysctl.conf /etc/sysctl.d/90-latchkey.conf 644; then sysctl -q --system >/dev/null; fi
if put docker-daemon.json /etc/docker/daemon.json 644; then
  # Restarting Docker restarts the containers (live-restore only helps from the next restart on).
  systemctl restart docker
  say "restarted Docker with its new settings"
fi
# SSH: harden.sh checks a new connection works, then cancels the timer that would undo this.
if [ -f sshd.conf ] && ! cmp -s sshd.conf /etc/ssh/sshd_config.d/01-latchkey.conf 2>/dev/null; then
  install -m 644 sshd.conf /etc/ssh/sshd_config.d/01-latchkey.conf
  if ! sshd -t; then
    rm -f /etc/ssh/sshd_config.d/01-latchkey.conf
    echo "FAIL: the SSH server refused the new settings; they were taken out again" >&2
    exit 1
  fi
  systemctl stop latchkey-sshd-undo.timer >/dev/null 2>&1 || true
  systemd-run --quiet --unit latchkey-sshd-undo --on-active=300 /bin/sh -c \
    'rm -f /etc/ssh/sshd_config.d/01-latchkey.conf; systemctl try-reload-or-restart ssh'
  systemctl try-reload-or-restart ssh
  say "new SSH settings (undone in 5 minutes unless harden.sh confirms a new connection)"
fi

# --- Accounts: only OS Login accounts sign in; the old local ones can't ---
for u in tonimelisma ubuntu; do
  id "$u" >/dev/null 2>&1 || continue
  for g in docker google-sudoers sudo adm; do
    if id -nG "$u" | tr ' ' '\n' | grep -qx "$g"; then gpasswd -d "$u" "$g" >/dev/null && say "$u left group $g"; fi
  done
  home=$(getent passwd "$u" | cut -d: -f6)
  if [ -s "$home/.ssh/authorized_keys" ]; then : >"$home/.ssh/authorized_keys" && say "$u's SSH keys removed"; fi
  if [ "$(getent passwd "$u" | cut -d: -f7)" != /usr/sbin/nologin ]; then
    usermod -L -s /usr/sbin/nologin "$u" && say "$u locked"
  fi
done
if [ -f /etc/sudoers.d/90-cloud-init-users ]; then rm -f /etc/sudoers.d/90-cloud-init-users && say "removed the ubuntu account's sudo rule"; fi
for d in /opt/hackernews /opt/reverse-proxy; do
  if [ -n "$(find "$d" ! -user root -print -quit 2>/dev/null)" ]; then chown -R root:root "$d" && say "$d now belongs to root"; fi
done
[ ! -f /opt/hackernews/.env ] || chmod 600 /opt/hackernews/.env
if [ -d /opt/voice-decommission ]; then rm -rf /opt/voice-decommission && say "deleted the old voice backups"; fi

# --- Docker: each app on its own network with Caddy, so neither can reach the other ---
for net in latchkey-front hackernews-front; do
  docker network inspect "$net" >/dev/null 2>&1 || { docker network create "$net" >/dev/null && say "created network $net"; }
done
# The relay joins its network now, so Caddy reaches it before the next deploy moves it there.
if docker inspect latchkey-relay >/dev/null 2>&1 &&
  ! docker inspect latchkey-relay --format '{{json .NetworkSettings.Networks}}' | grep -q '"latchkey-front"'; then
  docker network connect latchkey-front latchkey-relay && say "relay joined latchkey-front"
fi
# hackernews: a fixed compose file (no longer pulled from its repository), the public image
# pulled by the timer below, no root inside, no extra privileges.
vol=/var/lib/docker/volumes/hackernews_sqlite-data/_data
if [ -d "$vol" ] && [ -n "$(find "$vol" ! -user 1000 -print -quit)" ]; then chown -R 1000:1000 "$vol" && say "hackernews data now belongs to its app user"; fi
hn_changed=''
put hackernews-compose.yml /opt/hackernews/docker-compose.yml 644 && hn_changed=1
put caddy-compose.yml /opt/reverse-proxy/docker-compose.yml 644 && caddy_changed=1 || caddy_changed=''
if [ -n "$hn_changed" ] || ! docker inspect hackernews-app-1 --format '{{json .NetworkSettings.Networks}}' 2>/dev/null | grep -q hackernews-front; then
  (cd /opt/hackernews && docker compose up -d --quiet-pull --remove-orphans >/dev/null 2>&1) && say "hackernews restarted with its new settings"
fi
if [ -n "$caddy_changed" ]; then
  (cd /opt/reverse-proxy && docker compose up -d --quiet-pull >/dev/null 2>&1) && say "Caddy restarted with its new settings"
fi
put update-apps.sh /usr/local/sbin/latchkey-update-apps 755 || true
put latchkey-update-apps.service /etc/systemd/system/latchkey-update-apps.service 644 || true
put latchkey-update-apps.timer /etc/systemd/system/latchkey-update-apps.timer 644 || true

# Old relay images: the running one and the newest two stay (the deploy's rollback needs one).
running=$(docker inspect latchkey-relay --format '{{.Config.Image}}' 2>/dev/null || true)
docker images latchkey-relay --format '{{.CreatedAt}}\t{{.Repository}}:{{.Tag}}' | sort -r | cut -f2 | tail -n +3 |
  while read -r img; do [ "$img" = "$running" ] || docker rmi "$img" >/dev/null 2>&1 || true; done
docker image prune -f >/dev/null 2>&1 || true

# --- Intrusion detection ---
put sentinel.py /usr/local/sbin/latchkey-sentinel 755 && sentinel_changed=1 || sentinel_changed=''
put sentinel.json /etc/latchkey-sentinel.json 644 && sentinel_changed=1 || true
put latchkey-sentinel.service /etc/systemd/system/latchkey-sentinel.service 644 && sentinel_changed=1 || true
if put audit.rules /etc/audit/rules.d/latchkey.rules 640; then
  rm -f /etc/audit/rules.d/audit.rules
  if auditctl -s | grep -q '^enabled 2'; then
    reboot_needed=1 # locked: the new rules load at the next start
    say "new audit rules load at the next restart"
  else
    augenrules --load >/dev/null && say "audit rules loaded (locked until the next restart)"
  fi
fi
systemctl daemon-reload
systemctl enable --now auditd >/dev/null 2>&1
systemctl enable --now latchkey-update-apps.timer >/dev/null 2>&1
systemctl enable latchkey-sentinel >/dev/null 2>&1
if [ -n "$sentinel_changed" ] || ! systemctl is-active -q latchkey-sentinel; then
  systemctl restart latchkey-sentinel && say "sentinel (re)started"
fi

# --- Updates: everything pending now; afterwards unattended-upgrades keeps up ---
apt-get -y -q update >/dev/null
upgradable=$(apt-get -s -o Dpkg::Options::=--force-confold dist-upgrade | grep -c '^Inst' || true)
if [ "$upgradable" -gt 0 ]; then
  apt-get -y -q -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef dist-upgrade >/dev/null
  say "installed $upgradable updates"
fi
apt-get -y -q autoremove --purge >/dev/null 2>&1 || true
[ ! -f /var/run/reboot-required ] || reboot_needed=1
if [ -n "$reboot_needed" ]; then echo REBOOT; fi
