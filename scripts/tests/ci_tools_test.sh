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

# Every action is pinned to a full commit SHA (a tag can be moved to other code).
unpinned=$(grep -hE '^\s*(- )?uses: ' "$root"/.github/workflows/*.yml | grep -vE 'uses: [^@ ]+@[0-9a-f]{40}( |$)' || true)
if [ -z "$unpinned" ]; then ok "every action is pinned to a commit SHA"; else bad "actions not pinned to a commit SHA: $unpinned"; fi

# Every job that releases what servers or the Mac install, deploys, or changes infrastructure runs
# in its approval environment (the owner can require reviewers there): name the workflow, the job
# and the environment.
gate() { # <workflow> <job> <environment>
  if awk -v job="  $2:" -v env="    environment: $3" '
    $0 == job { injob = 1; next }
    injob && /^  [a-z]/ { injob = 0 }
    injob && $0 == env { found = 1 }
    END { exit !found }' "$root/.github/workflows/$1"; then
    ok "$1 job $2 runs in the environment $3"
  else
    bad "$1 job $2 must run in the environment $3"
  fi
}
gate relay-image.yml image production
gate linux-release.yml release release
gate mac-tag.yml tag release
gate mac-tag.yml release release
# Nothing outside those jobs gets write access to the repository, packages or an identity token.
for f in "$root"/.github/workflows/*.yml; do
  if awk '
    /^  [a-z][a-z0-9_-]*:$/ { env = 0 }
    /^    environment: / { env = 1 }
    /^      (contents|packages|id-token): write/ && !env { bad = 1 }
    END { exit bad }' "$f"; then
    ok "$(basename "$f"): writes and identity tokens only in gated jobs"
  else
    bad "$(basename "$f"): a job without an approval environment asks for write access or an identity token"
  fi
done

[ "$fails" -eq 0 ] || { printf '%s failed\n' "$fails"; exit 1; }
