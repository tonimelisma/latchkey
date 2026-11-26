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
has "no token, no terminal: says to run evals.sh in Terminal once" "$(FAKE_IMAGES=latchkey-eval run "$weekly" </dev/null)" "run macos/scripts/evals.sh once in Terminal"
# Regression (first local run, 2026-11-26): eval-image.sh asked for the Claude token and then
# for Enter, so it couldn't run to the end unattended, and the sandbox waited on a token only the
# evals use. It now checks the permissions again until they are approved.
if grep -qE '(^|[^a-z_])read -r' "$image"; then bad "eval-image.sh never waits for a key press"; else ok "eval-image.sh never waits for a key press"; fi
if grep -v '^#' "$image" | grep -q 'TOKEN_SERVICE\|claude_token'; then bad "eval-image.sh needs no Claude token"; else ok "eval-image.sh needs no Claude token"; fi
grep -q 'until_ready "the permissions" .*e2e-bin sandbox -checks tools' "$image" && ok "eval-image.sh checks the permissions" || bad "permission check loop"
# Regression (first local run, 2026-11-26): the test Mac's window opened on the owner's screen
# with about twenty approvals for a person, and the release installed first left keychain items
# the sandbox build was then asked about.
if grep -v '^#' "$image" | grep -E '"\$TART" run ' | grep -qv -- '--no-graphics'; then bad "the test Mac never gets a window"; else ok "the test Mac never gets a window"; fi
if grep -v '^#' "$image" | grep -qE '^\s*install_latchkey "'; then bad "eval-image.sh installs no release"; else ok "eval-image.sh installs no release"; fi
g=$(grep -n '^vm_grant_permissions' "$image" | cut -d: -f1)
o=$(grep -n '^vm_open_latchkey' "$image" | cut -d: -f1)
[ -n "$g" ] && [ -n "$o" ] && [ "$g" -lt "$o" ] && grep -q 'install_latchkey_build "$BUILD" "$SANDBOX_APP" no-open' "$image" &&
	ok "the permissions are granted before Latchkey first starts" || bad "grant before the first start (grant line $g, open line $o)"
grep -q 'mdutil -i on' "$image" && ok "eval-image.sh turns Spotlight on (files_find searches with it)" || bad "Spotlight on"
grep -q 'prepare -confirm' "$image" && ok "the pairing's Connect is answered inside the test Mac" || bad "prepare -confirm"
grep -q 'csrutil status' "$root/macos/scripts/vm-permissions.zsh" && ok "the grant script refuses a Mac with System Integrity Protection on" || bad "SIP guard"
# The local build needs Xcode; --release doesn't.
noxcode=$work/noxcode
mkdir -p "$noxcode"
for f in "$bin"/*; do case "$(basename "$f")" in xcodebuild | xcodegen) ;; *) cp "$f" "$noxcode/" ;; esac; done
# Like the stub /usr/bin/xcodebuild of a Mac without Xcode, which is on PATH there too: it
# fails when run (2026-11-26: on a Mac these tests found the real Xcode through /usr/bin).
printf '#!/bin/sh\nexit 1\n' >"$noxcode/xcodebuild"
chmod +x "$noxcode/xcodebuild"
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
