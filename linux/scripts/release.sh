#!/bin/sh
# Builds, signs, and publishes the server program as GitHub release linux-<x.y.z> (spec 010
# plan D12): latchkey-linux-amd64 and -arm64, each with its .sig, and SHA256SUMS for install.sh.
# Needs SERVER_SIGNING_KEY (in the gitignored ../.env) and the GitHub CLI signed in. Publishes only
# a clean checkout at origin/main, so every release is code that's on main.
set -eu
cd "$(dirname "$0")/.."

# shellcheck source=/dev/null
[ -f ../.env ] && . ../.env
[ -n "${SERVER_SIGNING_KEY:-}" ] || { echo "release: SERVER_SIGNING_KEY isn't in ../.env" >&2; exit 1; }
if [ "${RELEASE_ALLOW_DIRTY:-}" != 1 ]; then
  [ -z "$(git status --porcelain)" ] || { echo "release: the checkout has uncommitted changes" >&2; exit 1; }
  git fetch -q origin main
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "release: HEAD isn't origin/main" >&2; exit 1; }
fi
# The number is this commit's tag, linux-<x.y.z>, given or reused (Toni, 2026-11-04: releases are
# tags on commits, so two sessions never publish the same number). The release goes on that tag.
# RELEASE_TAG_PREFIX=server-v only for the one bridge release (0.1.4, 2026-11-04) that servers
# knowing only that name update to; it reads both names.
prefix=${RELEASE_TAG_PREFIX:-linux-}
version=$(../scripts/release-tag.sh "$prefix")
tag=$prefix$version
if gh release view "$tag" >/dev/null 2>&1; then
  echo "release: $tag is already published; this commit is released" >&2
  exit 1
fi

rm -rf build
make build VERSION="$version"
SERVER_SIGNING_KEY=$SERVER_SIGNING_KEY go run ./cmd/sign "$version" build/latchkey-linux-amd64 build/latchkey-linux-arm64
(cd build && shasum -a 256 latchkey-linux-amd64 latchkey-linux-arm64 > SHA256SUMS) # the format sha256sum -c reads
cp install.sh build/install.sh
gh release create "$tag" --verify-tag --title "Latchkey for Linux servers $version" \
  --notes "Install on a server (as yourself, not root): \`curl -fsSL https://raw.githubusercontent.com/tonimelisma/latchkey/main/linux/install.sh | sh -s -- https://your-relay\`. Installed servers update themselves; each download's signature is checked against the key built into the program." \
  build/latchkey-linux-amd64 build/latchkey-linux-amd64.sig build/latchkey-linux-arm64 build/latchkey-linux-arm64.sig build/SHA256SUMS build/install.sh
rm -rf build
echo "Published $tag"
