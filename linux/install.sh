#!/bin/sh
# Latchkey for Linux servers: installs the program and connects this server to your account
# (spec 010 FR-1026; contracts/server-program.md). Run it as yourself, not as root:
#
#   curl -fsSL https://raw.githubusercontent.com/tonimelisma/latchkey/main/linux/install.sh | sh -s -- https://your-relay
#
# It checks this system, downloads the newest release for its processor from GitHub, checks the
# download against the release's SHA256SUMS, and runs `latchkey install`, which shows a code to
# enter on your relay's page and starts the service (sudo asks for your password once if it
# needs one). From then on Latchkey updates itself, checking each update's signature.
#
# For a fork or a test: LATCHKEY_REPO=owner/name, LATCHKEY_VERSION=0.1.0, or LATCHKEY_BASE_URL
# (a folder with latchkey-linux-<arch> and SHA256SUMS, used as is).
set -eu

relay=${1:-}
shift 2>/dev/null || true
repo=${LATCHKEY_REPO:-tonimelisma/latchkey}

say() { printf '%s\n' "$*"; }
die() { printf 'latchkey: %s\n' "$*" >&2; exit 1; }

[ -n "$relay" ] || die "give your relay's address: curl … | sh -s -- https://your-relay"
[ "$(uname -s)" = Linux ] || die "this installer is for Linux servers; on a Mac, install the Latchkey app"
[ "$(id -u)" != 0 ] || die "run it as yourself, not as root: Latchkey runs as your own account and uses your sudo where you allow it"
case $(uname -m) in
  x86_64 | amd64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) die "Latchkey runs on 64-bit Intel/AMD and Arm processors, not $(uname -m)" ;;
esac
[ -d /run/systemd/system ] || die "this system doesn't run systemd, which Latchkey needs to start at boot"
[ -f /sys/fs/cgroup/cgroup.controllers ] || die "this system has no cgroup v2 (Ubuntu 22.04 and Debian 11 or newer have it)"
command -v curl >/dev/null || die "curl is needed"
command -v sha256sum >/dev/null || die "sha256sum is needed"
command -v sudo >/dev/null || die "sudo is needed to install the service"

if [ -n "${LATCHKEY_BASE_URL:-}" ]; then
  base=$LATCHKEY_BASE_URL
else
  tag=${LATCHKEY_VERSION:+server-v$LATCHKEY_VERSION}
  if [ -z "$tag" ]; then # GitHub lists releases newest first
    tag=$(curl -fsSL "https://api.github.com/repos/$repo/releases?per_page=50" |
      grep -o '"tag_name": *"server-v[0-9.]*"' | head -n 1 | sed 's/.*"\(server-v[0-9.]*\)"/\1/') || true
  fi
  [ -n "$tag" ] || die "no Latchkey server release found in $repo"
  base=https://github.com/$repo/releases/download/$tag
fi

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT INT TERM
say "Downloading Latchkey for $arch…"
curl -fsSL -o "$dir/latchkey-linux-$arch" "$base/latchkey-linux-$arch" || die "couldn't download $base/latchkey-linux-$arch"
curl -fsSL -o "$dir/SHA256SUMS" "$base/SHA256SUMS" || die "couldn't download $base/SHA256SUMS"
(cd "$dir" && grep " latchkey-linux-$arch\$" SHA256SUMS | sha256sum -c --quiet -) || die "the download doesn't match the release's checksum"
chmod 755 "$dir/latchkey-linux-$arch"
"$dir/latchkey-linux-$arch" install --relay "$relay" "$@"
