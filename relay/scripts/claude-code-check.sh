#!/bin/sh
# Runs the Claude Code check: a private relay, sign-up and pairing in headless Chrome, then Claude
# Code calling the pretend Mac's tools through the relay. Needs Chrome and Claude Code installed.
set -eu
cd "$(dirname "$0")/.."
exec go run ./cmd/localcheck "$@"
