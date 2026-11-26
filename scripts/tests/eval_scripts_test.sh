#!/bin/sh
# Tests for macos/scripts/evals.sh and eval-image.sh (spec 015; spec 016 plan D4): their options,
# and that each stops with the fix in plain words when something it needs is missing, before
# touching anything. Tart, uname, Xcode and the keychain are stand-ins on PATH.
# Run: scripts/tests/eval_scripts_test.sh (or `make -C relay script-tests`).
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
has() { if printf '%s' "$2" | grep -q -- "$3"; then ok "$1"; else bad "$1 (wanted '$3' in: $2)"; fi; }

bin=$work/bin
mkdir -p "$bin"
# uname says what FAKE_UNAME_S / FAKE_UNAME_M say.
cat >"$bin/uname" <<'S'
#!/bin/sh
case "$1" in -s) echo "${FAKE_UNAME_S:-Darwin}" ;; -m) echo "${FAKE_UNAME_M:-arm64}" ;; *) echo Darwin ;; esac
S
# tart: knows `exec --help`, lists FAKE_IMAGES, records every other call.
cat >"$bin/tart" <<'S'
#!/bin/sh
echo "$*" >>"$TART_LOG"
case "$1" in
exec) [ "${2:-}" = --help ] && exit 0; exit 1 ;;
list) for i in ${FAKE_IMAGES:-}; do echo "$i"; done ;;
esac
S
# security: no token unless FAKE_TOKEN is set.
cat >"$bin/security" <<'S'
#!/bin/sh
[ -n "${FAKE_TOKEN:-}" ] && { echo "$FAKE_TOKEN"; exit 0; }
exit 44
S
for t in go xcodebuild xcodegen; do printf '#!/bin/sh\nexit 0\n' >"$bin/$t"; done
chmod +x "$bin"/*
export TART_LOG="$work/tart.log"
run() { PATH="$bin:/usr/bin:/bin" "$@" 2>&1; }
weekly=$root/macos/scripts/evals.sh
image=$root/macos/scripts/eval-image.sh

has "evals --help says what it does" "$(run "$weekly" --help)" "stay in this clone"
has "evals --help names --send" "$(run "$weekly" --help)" "--send"
has "evals --help names --release" "$(run "$weekly" --help)" "--release"
has "an unknown option is refused" "$(run "$weekly" --sned)" "unknown option --sned"
has "eval-image takes no options" "$(run "$image" --force)" "takes none"
has "not a Mac: says so" "$(FAKE_UNAME_S=Linux run "$weekly")" "runs on a Mac"
has "an Intel Mac: says Apple silicon" "$(FAKE_UNAME_M=x86_64 run "$weekly")" "Apple silicon"
has "no image yet: says to run eval-image.sh" "$(run "$weekly")" "run macos/scripts/eval-image.sh once first"
has "no token: says where it comes from" "$(FAKE_IMAGES=latchkey-eval run "$weekly")" "no Claude token"
# The local build needs Xcode; --release doesn't.
noxcode=$work/noxcode
mkdir -p "$noxcode"
for f in "$bin"/*; do case "$(basename "$f")" in xcodebuild | xcodegen) ;; *) cp "$f" "$noxcode/" ;; esac; done
has "the local build without Xcode: says so" "$(PATH="$noxcode:/usr/bin:/bin" "$weekly" 2>&1)" "Xcode isn't installed"
has "--release needs no Xcode" "$(PATH="$noxcode:/usr/bin:/bin" "$weekly" --release 2>&1)" "run macos/scripts/eval-image.sh once first"
has "eval-image needs Xcode (it builds the sandbox-signed app)" "$(PATH="$noxcode:/usr/bin:/bin" "$image" 2>&1)" "Xcode isn't installed"
if grep -q 'install_latchkey_build' "$image" && grep -q 'sandbox_build' "$image"; then
	ok "eval-image approves permissions for a sandbox-signed build"
else
	bad "eval-image.sh must install a sandbox-signed build before the permissions are approved"
fi
if grep -qE '^(clone|run|delete)' "$TART_LOG" 2>/dev/null; then
	bad "nothing was copied, started or deleted before the checks passed ($(cat "$TART_LOG"))"
else
	ok "nothing was copied, started or deleted before the checks passed"
fi
if grep -q 'ANTHROPIC_API_KEY' "$weekly" && grep -q 'unset ANTHROPIC_API_KEY' "$weekly"; then
	ok "the run never passes an API key to Claude Code (it would bill API credits)"
else
	bad "evals.sh must unset ANTHROPIC_API_KEY in the test Mac"
fi
if grep -q -- '--bare' "$root/relay/cmd/e2e/weekly.go"; then
	bad "Claude Code must not run with --bare (it ignores the subscription token)"
else
	ok "Claude Code runs without --bare"
fi
if git -C "$root" check-ignore -q e2e-results/x.json; then ok "e2e-results/ is ignored by git"; else bad "e2e-results/ must be ignored by git"; fi

[ "$fails" -eq 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
