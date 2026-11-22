#!/bin/sh
# CI's runner has every tool `make security` calls. ubuntu-latest has Go (setup-go), Docker and
# curl, but no uv, so the workflow sets up uv whenever the Makefile runs anything with uvx
# (CI was red from 2026-11-21 to 2026-11-22: "uvx: not found" in `make semgrep`).
# Run: scripts/tests/ci_tools_test.sh (or `make -C relay script-tests`).
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

if grep -q 'uvx' "$root/relay/Makefile"; then
  if grep -qE '^\s*- uses: astral-sh/setup-uv@[0-9a-f]{40} ' "$root/.github/workflows/ci.yml"; then
    ok "CI sets up uv, pinned to a commit, for the Makefile's uvx"
  else
    bad "relay/Makefile runs uvx but .github/workflows/ci.yml doesn't set up uv (astral-sh/setup-uv pinned to a commit SHA)"
  fi
else
  ok "the Makefile runs nothing with uvx"
fi

[ "$fails" -eq 0 ] || { printf '%s failed\n' "$fails"; exit 1; }
