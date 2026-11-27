#!/bin/bash
# Prepares the test Mac for the sandbox and the evals, once (spec 015 FR-1512, FR-1513, plan D6;
# spec 016 plan D3). Run it from a clone, on an Apple silicon Mac with Tart, Go, Xcode and
# XcodeGen (about 40 GB free; the first time downloads a 27 GB base image):
#
#   macos/scripts/eval-image.sh
#
# It makes a virtual Mac from a clean base image (none of this Mac's data goes in) and never
# shows it: no window, nothing on this Mac's screen, nobody approves anything. Inside it: Chrome
# and Claude Code, Latchkey built from this clone and signed with the sandbox's own identity
# (sandbox.sh), its macOS permissions written into the test Mac's permission databases
# (vm-permissions.zsh; the base image has System Integrity Protection off, as Tart's images do),
# a private relay with its test certificate, Latchkey paired with that relay (the script answers
# Latchkey's Connect question inside the test Mac), and each kind of test data made once. The
# image is kept as $LATCHKEY_EVAL_IMAGE (latchkey-eval); each sandbox or eval run uses a copy of
# it. Run it again after a new macOS or when a run says a permission is missing.
#
# Every sandbox build carries the same signature, so the permissions hold for each new build;
# install_latchkey_build also lets each new build read the pairing in the keychain. evals.sh
# --release installs the CI-signed release instead, whose signature differs: its permissions
# aren't in the image. (2026-11-26, the first run: the release installed first left keychain
# items the sandbox build then asked about, and about twenty approvals waited on a person.)
set -eu
. "$(dirname "$0")/eval-lib.sh"

case "${1:-}" in
-h | --help)
	sed -n '2,22p' "$0"
	exit 0
	;;
"") ;;
*) die "unknown option $1 (eval-image.sh takes none)" ;;
esac
need_tools
need_build_tools
BUILD=$EVAL_IMAGE-build
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if image_exists "$BUILD"; then vm_remove "$BUILD"; fi
say "copying the base image $EVAL_BASE (the first time downloads about 27 GB)"
"$TART" clone "$EVAL_BASE" "$BUILD"
"$TART" set "$BUILD" --cpu 4 --memory 8192 >/dev/null 2>&1 || true
say "starting it without a window"
"$TART" run --no-graphics "$BUILD" >"$WORK/run.log" 2>&1 &
wait_vm "$BUILD"

say "installing Google Chrome (for the relay's sign-in pages) and Claude Code"
vm "$BUILD" 'set -e; t=$(mktemp -d); curl -fsSL -o "$t/chrome.dmg" https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg
mnt=$(hdiutil attach -nobrowse -readonly "$t/chrome.dmg" | awk -F"\t" "/Volumes/ {print \$NF}" | tail -1)
rm -rf "/Applications/Google Chrome.app"; cp -R "$mnt/Google Chrome.app" /Applications/; hdiutil detach -quiet "$mnt"; rm -rf "$t"'
vm "$BUILD" 'curl -fsSL https://claude.ai/install.sh | bash && grep -q .local/bin ~/.zprofile 2>/dev/null || echo "export PATH=\$HOME/.local/bin:\$PATH" >> ~/.zprofile'

say "building Latchkey from this clone, signed with the sandbox's identity"
sandbox_identity
sandbox_build

say "the private relay's test certificate and name (only the test Mac trusts and resolves them)"
build_e2e "$WORK/e2e"
push_run "$BUILD" "$WORK/e2e"
vm "$BUILD" "$VM_DIR/e2e-bin prepare -certs" >/dev/null
vm_home=$(vm "$BUILD" 'printf %s "$HOME"')
vm_sudo "$BUILD" "security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain '$vm_home/latchkey-eval-state/ca.pem'"
# The relay's name, and the two sites the Safari checks serve their pages from (pageSites in
# relay/cmd/e2e/weekly.go): https, as real sites are (the third sandbox run, 2026-11-26).
for h in relay.latchkey.test site-one.test site-two.test; do
	vm_sudo "$BUILD" "grep -q ' $h\$' /etc/hosts || echo '127.0.0.1 $h' >> /etc/hosts"
done
# Spotlight, which files_find searches with: the base image has indexing off (the sandbox's
# first run, 2026-11-26: the search never found a file).
vm_sudo "$BUILD" "mdutil -i on / /System/Volumes/Data >/dev/null"

say "installing the sandbox-signed build ($SANDBOX_LABEL) and granting its permissions before it first starts"
install_latchkey_build "$BUILD" "$SANDBOX_APP" no-open
vm_grant_permissions "$BUILD"
vm_open_latchkey "$BUILD"

say "pairing the test Mac's Latchkey with its private relay (Connect is answered inside the test Mac)"
vm "$BUILD" "cd $VM_DIR && ./e2e-bin prepare -confirm"
# The apps the test data lives in start for the first time here, and macOS may take a moment
# with each: tried again up to WAIT_ROUNDS times, 20 s apart.
WAIT_ROUNDS=${LATCHKEY_EVAL_IMAGE_WAIT_ROUNDS:-9}
until_ready() { # until_ready WHAT COMMAND: COMMAND inside the test Mac until it succeeds
	local what=$1 i=0
	shift
	until vm "$BUILD" "$*"; do
		i=$((i + 1))
		[ "$i" -lt "$WAIT_ROUNDS" ] || die "$what still not ready after $((WAIT_ROUNDS * 20 / 60)) minutes (above)."
		say "$what: not yet (above); trying again in 20 s"
		sleep 20
	done
}
say "making each kind of test data once"
until_ready "the test data" "cd $VM_DIR && ./e2e-bin fixture 'fixture notes shopping' 'sweep notes' 'fixture calendar empty' 'sweep calendar' 'fixture reminders empty' 'sweep reminders' 'fixture contacts jordan' 'sweep contacts' 'fixture files todo' 'sweep files'"

# An app's first start on a Mac asks things of its own ("'Mail' Notifications…") and sets itself up
# slowly: in a fresh sandbox copy that happened during the checks, which counted the questions as
# Latchkey's and timed out on Contacts (2026-11-27). Each app Latchkey drives starts once here,
# hidden, and quits; nothing of it shows on this Mac.
say "starting each app Latchkey drives once, hidden, so their first starts happen now"
vm "$BUILD" 'for a in Mail Messages Notes Contacts Calendar Reminders Safari Maps Finder; do open -g -j -a "$a" || true; done; sleep 30
for a in Mail Messages Notes Contacts Calendar Reminders Maps; do osascript -e "tell application \"$a\" to quit" >/dev/null 2>&1 || true; done'

say "checking the permissions (the sandbox's own check)"
until_ready "the permissions" "cd $VM_DIR && ./e2e-bin sandbox -checks tools -out /tmp/check.json"
vm "$BUILD" "rm -rf $VM_DIR /tmp/check.json"
"$TART" stop "$BUILD"
if image_exists "$EVAL_IMAGE"; then vm_remove "$EVAL_IMAGE"; fi
"$TART" rename "$BUILD" "$EVAL_IMAGE"
say "the test Mac image $EVAL_IMAGE is ready: make -C macos sandbox (after each Mac build), make -C macos evals"
