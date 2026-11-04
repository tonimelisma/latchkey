#!/bin/bash
# Runs Latchkey's real SafariBrowser against the real Safari (scripts/safari-check/main.swift):
# same-site and cross-site clicks keep Claude's tab, a script's navigation loses it, a long page
# comes in parts, and another tab is listed, read, clicked, and closed in the background. Run it
# from a terminal that may control Safari, with the Mac unlocked (opening windows while locked
# stalls Safari); it opens a Safari window of its own and closes it afterwards.
# LATCHKEY_READ_OWNER_TAB=1 also reads one of the Owner's tabs (reading only);
# LATCHKEY_CHECK_ONLY=text runs only the checks whose name contains it. Needs the network and
# Safari's "Allow JavaScript from Apple Events".
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -O -D DEBUG -swift-version 6 -o "$out/safari-check" \
    App/Browser/SafariBrowser.swift App/Browser/PageScripts.swift App/Browser/PageAnswer.swift App/ScriptRunner.swift \
    App/ResultLimit.swift App/Computer/Screen.swift Shared/AppIdentity.swift scripts/safari-check/Shims.swift scripts/safari-check/main.swift
"$out/safari-check"
