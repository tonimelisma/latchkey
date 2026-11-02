#!/bin/bash
# Runs Latchkey's real Mail compose code against the real Mail (scripts/mail-check/main.swift), in
# whatever screen state the Mac is in, to see that writing email works there (lid closed included).
# Run it from a terminal that has Accessibility. Usage: mail-check.sh <to> <draft|send|probe>
# (send really sends: use your own address). See main.swift for MAIL_CHECK_NAME and MAIL_CHECK_FILE.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -O -D DEBUG -swift-version 6 -o "$out/mail-check" \
    App/Mail/MailCompose.swift App/Mail/MailWindows.swift App/Mail/MailClipboard.swift App/Computer/Screen.swift \
    scripts/mail-check/stubs.swift scripts/mail-check/main.swift
"$out/mail-check" "$@"
