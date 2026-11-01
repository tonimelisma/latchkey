#!/bin/sh
# Runs the Linux program's tests on a real Linux with systemd (make test-linux): the unit tests as
# root, then as the owner (toni) inside a systemd service with its own delegated control group,
# as the real service runs, and the sudo-prompt test as a user whose sudo asks for a password.
# Removes its container afterwards.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
name=latchkey-linux-test-$$
image=latchkey-linux-test

docker build -q -t "$image" "$here" >/dev/null
docker run -d --name "$name" --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v "$repo:/src:ro" --tmpfs /tmp:exec "$image" >/dev/null
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT INT TERM

i=0
until docker exec "$name" systemctl is-system-running 2>/dev/null | grep -Eq 'running|degraded'; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || { echo "systemd didn't start in the container" >&2; exit 1; }
  sleep 1
done

# The source is read-only; each user tests a copy, with its own Go caches.
as_user() { # user, then the command
  u=$1; shift
  docker exec "$name" systemd-run --quiet --wait --pipe --collect --uid="$u" -p Delegate=yes \
    -E HOME="/home/$u" -E GOCACHE="/home/$u/.cache/go-build" -E GOMODCACHE="/home/$u/go/pkg/mod" \
    -E GOFLAGS=-mod=mod -E PATH=/usr/local/go/bin:/usr/bin:/bin -E LATCHKEY_TEST_CGROUP=1 "$@"
}
docker exec "$name" sh -c 'for u in toni pw; do rm -rf /home/$u/src; cp -r /src /home/$u/src; chown -R $u:$u /home/$u/src; done'

echo "• unit tests as toni, in a service with its own control group"
as_user toni /bin/sh -c 'cd ~/src/linux && go test -count=1 ./...'
echo "• the sudo prompt test as a user whose sudo asks for a password"
docker exec "$name" systemd-run --quiet --wait --pipe --collect --uid=pw -p Delegate=yes \
  -E HOME=/home/pw -E GOCACHE=/home/pw/.cache/go-build -E GOMODCACHE=/home/pw/go/pkg/mod -E GOFLAGS=-mod=mod \
  -E PATH=/usr/local/go/bin:/usr/bin:/bin -E LATCHKEY_TEST_SUDO_PROMPT=1 \
  /bin/sh -c 'cd ~/src/linux && go test -count=1 -run TestSudo -v ./internal/shell/ | grep -E "^(---|ok|FAIL)"'
echo "PASS: the Linux tests passed on Debian with systemd"
