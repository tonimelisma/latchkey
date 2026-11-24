#!/bin/sh
# Tests for macos/scripts/weekly-eval.sh and eval-image.sh (spec 015): their options, and that
# each stops with the fix in plain words when something it needs is missing, before touching
# anything. Tart, uname and the keychain are stand-ins on PATH.
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
printf '#!/bin/sh\nexit 0\n' >"$bin/go"
chmod +x "$bin"/*
export TART_LOG="$work/tart.log"
run() { PATH="$bin:/usr/bin:/bin" "$@" 2>&1; }
weekly=$root/macos/scripts/weekly-eval.sh
image=$root/macos/scripts/eval-image.sh

has "weekly --help says what it does" "$(run "$weekly" --help)" "results stay in this clone"
has "weekly --help names --send" "$(run "$weekly" --help)" "--send"
has "an unknown option is refused" "$(run "$weekly" --sned)" "unknown option --sned"
has "eval-image takes no options" "$(run "$image" --force)" "takes none"
has "not a Mac: says so" "$(FAKE_UNAME_S=Linux run "$weekly")" "runs on a Mac"
has "an Intel Mac: says Apple silicon" "$(FAKE_UNAME_M=x86_64 run "$weekly")" "Apple silicon"
has "no image yet: says to run eval-image.sh" "$(run "$weekly")" "run macos/scripts/eval-image.sh once first"
has "no token: says where it comes from" "$(FAKE_IMAGES=latchkey-eval run "$weekly")" "no Claude token"
if grep -qE '^(clone|run|delete)' "$TART_LOG" 2>/dev/null; then
	bad "nothing was copied, started or deleted before the checks passed ($(cat "$TART_LOG"))"
else
	ok "nothing was copied, started or deleted before the checks passed"
fi
if grep -q 'ANTHROPIC_API_KEY' "$weekly" && grep -q 'unset ANTHROPIC_API_KEY' "$weekly"; then
	ok "the run never passes an API key to Claude Code (it would bill API credits)"
else
	bad "weekly-eval.sh must unset ANTHROPIC_API_KEY in the test Mac"
fi
if grep -q -- '--bare' "$root/relay/cmd/e2e/weekly.go"; then
	bad "Claude Code must not run with --bare (it ignores the subscription token)"
else
	ok "Claude Code runs without --bare"
fi
if git -C "$root" check-ignore -q e2e-results/x.json; then ok "e2e-results/ is ignored by git"; else bad "e2e-results/ must be ignored by git"; fi

[ "$fails" -eq 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
