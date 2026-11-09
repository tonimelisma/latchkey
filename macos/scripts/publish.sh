#!/bin/sh
# Publishes the installed release's disk image on GitHub (spec 001 FR-670): release mac-<version>
# with the asset Latchkey.dmg, so https://github.com/tonimelisma/latchkey/releases/latest/download/Latchkey.dmg
# is always the newest Mac app. install.sh runs it after an install passed its checks.
#   scripts/publish.sh <version>
# The app is signed for development, not notarized (no Developer ID yet; Toni, 2026-11-09): a
# downloaded copy opens after Privacy & Security → Open Anyway, once.
# Refuses an image that holds one of the deployment's private values (the relay's address, the
# server's names). The signer's name and team ID are in every signed app's signature; Toni chose
# to publish them (2026-11-09).
# Only the newest three Mac releases are kept, so GitHub's list of 50 newest releases, which the
# Linux program and its installer read, always has Linux releases in it; older tags stay.
set -eu
VERSION=${1:?usage: scripts/publish.sh <version>}
cd "$(dirname "$0")/.."
DMG=build/Latchkey-$VERSION.dmg
TAG=mac-$VERSION
KEEP=3
[ -f "$DMG" ] || { echo "publish: $DMG is missing" >&2; exit 1; }
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "publish: $TAG is already published"
  exit 0
fi

work=$(mktemp -d)
mnt="$work/mnt"
cleanup() {
  [ -d "$mnt" ] && hdiutil detach -quiet "$mnt" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

# The private values, read the way scripts/private-values-check.sh reads them. The DNS zone isn't
# searched: it is also the signer's email domain, published with the signature.
top=$(git rev-parse --show-toplevel)
main=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
private_file() {
  for dir in "$top" "$main"; do
    [ -f "$dir/$1" ] && { printf '%s\n' "$dir/$1"; return; }
  done
  return 0
}
env_file=$(private_file .env)
xc_file=$(private_file macos/Config/Local.xcconfig)
values=""
if [ -n "$env_file" ]; then
  for name in DEPLOY_HOST DEPLOY_VM DEPLOY_PROJECT; do
    v=$(sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$name=//p" "$env_file" | tail -1 |
      sed "s/[[:space:]]*\$//; s/^[\"']//; s/[\"']\$//")
    [ ${#v} -ge 6 ] && values="$values$name=$v
"
  done
fi
if [ -n "$xc_file" ]; then
  v=$(sed -n 's/^[[:space:]]*LATCHKEY_DEFAULT_RELAY_HOST[[:space:]]*=[[:space:]]*//p' "$xc_file" | tail -1 |
    sed 's|[[:space:]]*//.*$||; s/[[:space:]]*$//')
  [ ${#v} -ge 6 ] && values="${values}LATCHKEY_DEFAULT_RELAY_HOST=$v
"
fi

mkdir -p "$mnt"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mnt" "$DMG" || {
  echo "publish: couldn't open $DMG to check it (is it open elsewhere?)" >&2
  exit 1
}
found=0
printf '%s' "$values" | while IFS='=' read -r name value; do
  [ -n "$name" ] || continue
  if grep -r -a -i -q -F -- "$value" "$mnt" 2>/dev/null; then
    echo "publish: the disk image contains $name; not publishing" >&2
    exit 1
  fi
done || found=1
hdiutil detach -quiet "$mnt"
rmdir "$mnt"
[ "$found" = 0 ] || exit 1

cp "$DMG" "$work/Latchkey.dmg"
NOTES="Download **Latchkey.dmg** below, open it, and drag Latchkey to Applications. Needs a Mac with Apple silicon and macOS 26 or later.

The first time you open it, macOS says it can't check Latchkey (it isn't notarized by Apple yet). Click **Done**, open **System Settings → Privacy & Security**, scroll down, click **Open Anyway** next to Latchkey, and confirm. After that it opens like any app. Each new version you download asks this once again.

Latchkey's menu tells you when a newer version is out. How to set it up: https://github.com/tonimelisma/latchkey#get-started"
gh release create "$TAG" --verify-tag --latest --title "Latchkey $VERSION" --notes "$NOTES" "$work/Latchkey.dmg"
echo "publish: published $TAG"

# Older Mac releases go (their tags stay).
gh release list --limit 200 --json tagName --jq '.[].tagName' | sed -n 's/^mac-//p' |
  sort -t. -k1,1nr -k2,2nr -k3,3nr | tail -n +$((KEEP + 1)) | while read -r old; do
  gh release delete "mac-$old" --yes && echo "publish: removed the older release mac-$old (tag kept)"
done
