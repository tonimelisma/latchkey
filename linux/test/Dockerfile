# A Debian server for Latchkey's Linux tests (spec 010 plan D14): systemd as PID 1, sudo, and Go
# for the tests that need a real Linux. Two users: toni, with passwordless sudo, as most servers'
# owners set it up, and pw, whose sudo asks for a password.
FROM golang:1.27-bookworm

RUN apt-get update \
 && apt-get install -y --no-install-recommends systemd systemd-sysv dbus sudo curl procps ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && systemctl mask getty@.service console-getty.service systemd-firstboot.service systemd-remount-fs.service \
 && useradd -m -s /bin/bash toni \
 && echo 'toni ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/toni \
 && useradd -m -s /bin/bash pw \
 && echo 'pw:not-a-real-password' | chpasswd \
 && echo 'pw ALL=(ALL) ALL' > /etc/sudoers.d/pw \
 && chmod 440 /etc/sudoers.d/toni /etc/sudoers.d/pw

ENV container=docker
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
