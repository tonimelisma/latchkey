#!/bin/sh
# Fails if the Sparkle version the Mac app pins (macos/project.yml) has known advisories in the
# OSV database. OSV-Scanner can't read an XcodeGen project, so this asks the OSV API directly.
set -eu
cd "$(dirname "$0")/.."
VERSION=$(sed -n '/^  Sparkle:/,/^    revision:/s/^ *revision: *[0-9a-f]\{40\} *# *//p' macos/project.yml)
[ -n "$VERSION" ] || { echo "sparkle-advisories: no Sparkle version beside the pinned revision in macos/project.yml" >&2; exit 1; }
BODY=$(printf '{"package":{"name":"github.com/sparkle-project/Sparkle","ecosystem":"SwiftURL"},"version":"%s"}' "$VERSION")
RESULT=$(curl -fsS --max-time 30 -X POST https://api.osv.dev/v1/query -d "$BODY")
if [ "$RESULT" != "{}" ]; then
  echo "sparkle-advisories: Sparkle $VERSION has known advisories:" >&2
  echo "$RESULT" >&2
  exit 1
fi
echo "Sparkle $VERSION: no known advisories"
