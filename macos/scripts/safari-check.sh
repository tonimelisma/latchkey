#!/bin/bash
# Runs Latchkey's real SafariBrowser against the real Safari (scripts/safari-check/main.swift):
# a same-site click and script keep Claude's tab, a cross-site click loses it, a long page comes in
# parts. Run it from a terminal that may control Safari; it opens a Safari window of its own and
# closes it afterwards. Needs the network and Safari's "Allow JavaScript from Apple Events".
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -O -D DEBUG -swift-version 6 -o "$out/safari-check" \
    App/Browser/SafariBrowser.swift App/Browser/PageScripts.swift App/Browser/PageAnswer.swift App/ScriptRunner.swift \
    App/ResultLimit.swift Shared/AppIdentity.swift scripts/safari-check/main.swift
"$out/safari-check"
