#!/bin/sh
# Sets up a Claude Code cloud session (claude.ai/code: an Ubuntu 24.04 VM, run as root) for the
# relay's and the Linux program's checks: `make test`, `make lint`, `make security` and
# `make script-tests` in relay/ and linux/. Run by `scripts/hooks.sh session-start` only when
# CLAUDE_CODE_REMOTE=true; does nothing elsewhere (the Mac has its own tools from Homebrew).
#
# In the foreground, quick (well inside the 600 s a SessionStart hook may take):
#   - jq, lsof, xz, curl and gcc from Ubuntu when missing (the hooks need jq; the tidy and
#     loose-ends tests need lsof; `go test -race` needs a C compiler)
#   - Go from Ubuntu when there is none (the cloud image has one; go.mod's toolchain line then
#     fetches the pinned Go through proxy.golang.org)
#   - ShellCheck v0.11.0, the version `make shellcheck` pins, from its GitHub release, checked
#     against the SHA-256 below (the Makefile uses it instead of the Docker image when present)
#   - uv when missing (`make semgrep` runs the pinned Semgrep with uvx)
# In the background, logged to $LOG (it carries on after the hook returns; nothing waits on it):
#   Go modules of relay/ and linux/, the pinned Go tools the Makefiles `go run` (golangci-lint,
#   govulncheck, gitleaks, osv-scanner), the pinned Semgrep, and the test binaries, all into the
#   usual caches, so the first `make` is quick. A `make` started meanwhile just shares the caches.
#
# Network: everything here comes from hosts the "Limited" network allows by default. Some checks
# in `make security` fetch at run time from hosts it doesn't: semgrep.dev (Semgrep's rules),
# vuln.go.dev (govulncheck) and api.osv.dev (osv-scanner, sparkle-advisories.sh); they need those
# added to the cloud environment's allowed domains (CLAUDE.md, "Cloud sessions").
# Prints one line saying what it did. Tested in `docker run ubuntu:24.04` (CLAUDE.md).
set -u
[ "${CLAUDE_CODE_REMOTE:-}" = true ] || [ "${LATCHKEY_CLOUD_SETUP_FORCE:-}" = 1 ] || exit 0
repo=$(cd "$(dirname "$0")/.." && pwd)
LOG=${LATCHKEY_CLOUD_SETUP_LOG:-$HOME/.cache/latchkey-cloud-setup.log}
mkdir -p "$(dirname "$LOG")"
SHELLCHECK_VERSION=0.11.0
# shellcheck disable=SC2034 # read through eval below, by the machine's architecture
SHELLCHECK_SHA256_x86_64=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
# shellcheck disable=SC2034 # the same
SHELLCHECK_SHA256_aarch64=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588
done_list=""
note() { done_list="$done_list${done_list:+, }$1"; }
fail() { echo "cloud setup: $1 (log: $LOG)"; exit 0; }

as_root() { if [ "$(id -u)" = 0 ]; then "$@"; elif command -v sudo >/dev/null 2>&1; then sudo -n "$@"; else return 1; fi; }

# Ubuntu packages, one apt run for all that are missing.
need=""
for p in jq:jq lsof:lsof xz:xz-utils curl:curl make:make git:git python3:python3; do
  command -v "${p%%:*}" >/dev/null 2>&1 || need="$need ${p#*:}"
done
command -v go >/dev/null 2>&1 || need="$need golang-go"
command -v gcc >/dev/null 2>&1 || need="$need gcc libc6-dev" # go test -race needs cgo
if [ -n "$need" ]; then
  { as_root apt-get update -qq && DEBIAN_FRONTEND=noninteractive as_root apt-get install -y -qq --no-install-recommends ca-certificates $need; } >>"$LOG" 2>&1 ||
    fail "couldn't install$need from Ubuntu"
  note "installed$need"
fi

# Go: the relay's toolchain (go.mod's toolchain line) first on the PATH. go.mod alone makes a
# `go build` switch to it, but `go run tool@version` (the Makefiles' linters and scanners) builds
# the tool with its own module's minimum instead, and golangci-lint and govulncheck built with an
# older Go refuse the relay's newer one (checked in ubuntu:24.04, whose Go is 1.22).
want=$(sed -n 's/^toolchain //p' "$repo/relay/go.mod")
have=$(cd / && GOTOOLCHAIN=local go env GOVERSION 2>/dev/null)
if [ -n "$want" ] && [ "$(printf '%s\n%s\n' "$want" "$have" | sort -V | head -1)" != "$want" ]; then
  goroot=$(cd "$repo/relay" && go env GOROOT 2>>"$LOG") && [ -x "$goroot/bin/go" ] || fail "couldn't fetch $want"
  for b in go gofmt; do as_root ln -sf "$goroot/bin/$b" "/usr/local/bin/$b" || fail "couldn't put $want on the PATH"; done
  # Claude Code reads CLAUDE_ENV_FILE after a SessionStart hook: later commands get this PATH.
  [ -n "${CLAUDE_ENV_FILE:-}" ] && printf 'export PATH="%s/bin:$PATH"\n' "$goroot" >>"$CLAUDE_ENV_FILE"
  hash -r
  note "Go $want (was ${have:-none})"
fi

# ShellCheck, pinned.
if ! shellcheck --version 2>/dev/null | grep -qx "version: $SHELLCHECK_VERSION"; then
  arch=$(uname -m)
  case "$arch" in arm64) arch=aarch64 ;; esac
  eval "sum=\${SHELLCHECK_SHA256_$arch:-}"
  [ -n "$sum" ] || fail "no ShellCheck for $arch"
  tmp=$(mktemp -d)
  url="https://github.com/koalaman/shellcheck/releases/download/v$SHELLCHECK_VERSION/shellcheck-v$SHELLCHECK_VERSION.linux.$arch.tar.xz"
  curl -fsSL --retry 3 -o "$tmp/sc.tar.xz" "$url" >>"$LOG" 2>&1 || { rm -rf "$tmp"; fail "couldn't download ShellCheck"; }
  echo "$sum  $tmp/sc.tar.xz" | sha256sum -c --status || { rm -rf "$tmp"; fail "ShellCheck's download doesn't match its pinned SHA-256"; }
  tar -xJf "$tmp/sc.tar.xz" -C "$tmp" && as_root install -m 0755 "$tmp/shellcheck-v$SHELLCHECK_VERSION/shellcheck" /usr/local/bin/shellcheck ||
    { rm -rf "$tmp"; fail "couldn't install ShellCheck"; }
  rm -rf "$tmp"
  note "ShellCheck $SHELLCHECK_VERSION"
fi

# uv (preinstalled in the cloud image; from PyPI otherwise).
if ! command -v uvx >/dev/null 2>&1; then
  { command -v pip3 >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive as_root apt-get install -y -qq --no-install-recommends python3-pip; } >>"$LOG" 2>&1
  as_root pip3 install -q --break-system-packages uv >>"$LOG" 2>&1 || fail "couldn't install uv"
  note "uv"
fi

# The rest in the background, detached from the hook (setsid: a new session, so cancelling the
# hook doesn't stop it).
marker="$LOG.done"
rm -f "$marker"
setsid sh -c '
  cd "$1" || exit 1
  echo "warm-up started $(date -u +%FT%TZ)"
  for m in relay linux; do (cd "$m" && go mod download && go test -race -count=1 -run "^$" ./... >/dev/null) || echo "warm-up: $m failed"; done
  cd relay || exit 1
  # The pinned tools, read from relay/Makefile so the versions are written in one place. Only
  # the build matters (go run caches it): whatever --help exits with is ignored.
  for t in $(sed -n "s/^[A-Z_]* = go run \([^ ]*@[^ ]*\)$/\1/p" Makefile); do
    go run "$t" --help >/dev/null 2>&1; echo "warm-up: $t"
  done
  semgrep=$(sed -n "s/^SEMGREP = //p" Makefile)
  $semgrep --version >/dev/null || echo "warm-up: $semgrep failed"
  echo "warm-up finished $(date -u +%FT%TZ)"
  touch "$2"
' warm-up "$repo" "$marker" >>"$LOG" 2>&1 </dev/null &
note "warming Go modules, tools and test builds in the background (done when $marker exists)"
echo "cloud setup: ${done_list}. Log: $LOG"
