#!/bin/bash
# Runs Latchkey's real SafariBrowser against the real Safari (scripts/safari-check/main.swift):
# same-site and cross-site clicks keep Claude's tab, a script's navigation loses it, a long page
# comes in parts, another tab is listed, read, clicked, and closed in the background, and keys,
# hover, scrolling, lists, files in and out, and the picture copy work on a local test page
# (scripts/safari-check/pages, served from 127.0.0.1 while the check runs). Run it from a
# terminal that may control Safari, with the Mac unlocked (opening windows while locked stalls
# Safari); it opens a Safari window of its own and closes it afterwards, and removes every file
# it saved in Downloads.
# LATCHKEY_READ_OWNER_TAB=1 also reads one of the Owner's tabs (reading only);
# LATCHKEY_CHECK_ONLY=text runs only the checks whose name contains it. Needs the network and
# Safari's "Allow JavaScript from Apple Events".
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
server=""
cleanup() {
    if [ -n "$server" ]; then kill "$server" 2>/dev/null || true; fi
    rm -rf "$out"
}
trap cleanup EXIT
swiftc -O -D DEBUG -swift-version 6 -o "$out/safari-check" \
    App/Browser/SafariBrowser.swift App/Browser/PageScripts.swift App/Browser/PageActions.swift \
    App/Browser/PageAnswer.swift App/Browser/BrowserDownloads.swift App/ScriptRunner.swift \
    App/ResultLimit.swift App/Computer/Screen.swift Shared/AppIdentity.swift scripts/safari-check/Shims.swift \
    scripts/safari-check/main.swift
# The local test pages, with a 3 MB file made for this run.
cp -R scripts/safari-check/pages "$out/pages"
head -c 3000000 /dev/zero | tr '\0' 'A' >"$out/pages/files/latchkey-check-big.bin"
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$out/pages" >/dev/null 2>&1 &
server=$!
for _ in $(seq 50); do
    if curl -fsS "http://127.0.0.1:$port/actions.html" >/dev/null 2>&1; then break; fi
    sleep 0.1
done
LATCHKEY_PAGES="http://127.0.0.1:$port" "$out/safari-check"
