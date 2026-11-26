#!/bin/bash
# Prepares the test Mac for the sandbox and the evals, once (spec 015 FR-1512, FR-1513, plan D6;
# spec 016 plan D3). Run it in Terminal from a clone, on an Apple silicon Mac with Tart, Go,
# Xcode and XcodeGen:
#
#   macos/scripts/eval-image.sh
#
# It makes a virtual Mac from a clean base image (none of this Mac's data goes in), installs
# Chrome, Claude Code and the newest Latchkey release in it, a private relay's test certificate,
# and the test data's apps' first runs; then opens the test Mac's window once so the person
# running it clicks Connect and approves Latchkey's permissions, and checks again every 20 s
# until all are approved (no key press; the evals ask for their Claude token themselves,
# claude_token in eval-lib.sh). The image is
# kept as $LATCHKEY_EVAL_IMAGE (latchkey-eval); each sandbox or eval run uses a copy of it. Run it
# again after a new macOS or when a run says a permission is missing.
#
# The permissions are approved for a build signed with the sandbox's own identity (sandbox.sh,
# eval-lib.sh's sandbox_build), installed over the release just before the window opens: macOS
# files each permission, and Latchkey's pairing in the keychain, under the app's signature, and
# every sandbox build (make sandbox, make evals) carries that same signature, so the grants and
# the pairing hold for each new build. evals.sh --release installs the CI-signed release instead,
# whose signature differs: whether macOS keeps its grants too is checked on its first run.
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

if image_exists "$BUILD"; then "$TART" delete "$BUILD"; fi
say "copying the base image $EVAL_BASE (the first time downloads about 25 GB)"
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

say "installing the newest Latchkey release"
install_latchkey "$BUILD"
say "building Latchkey from this clone, signed with the sandbox's identity (the permissions are approved for it)"
sandbox_identity
sandbox_build

say "the private relay's test certificate and name (only the test Mac trusts and resolves them)"
build_e2e "$WORK/e2e"
push_run "$BUILD" "$WORK/e2e"
vm "$BUILD" "$VM_DIR/e2e-bin prepare -certs" >/dev/null
vm_home=$(vm "$BUILD" 'printf %s "$HOME"')
vm_sudo "$BUILD" "security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain '$vm_home/latchkey-eval-state/ca.pem'"
vm_sudo "$BUILD" "grep -q relay.latchkey.test /etc/hosts || echo '127.0.0.1 relay.latchkey.test' >> /etc/hosts"

say "installing the sandbox-signed build ($SANDBOX_LABEL) over the release"
install_latchkey_build "$BUILD" "$SANDBOX_APP"
say "restarting the test Mac with its window, for the steps only a person can do"
"$TART" stop "$BUILD" >/dev/null 2>&1 || true
"$TART" run "$BUILD" >"$WORK/run.log" 2>&1 &
wait_vm "$BUILD"
vm "$BUILD" 'open -a /Applications/Latchkey.app'
cat <<'EOF'

In the test Mac's window (not your own Mac):
  1. Latchkey opens its setup. Approve every permission it asks for: Full Disk Access,
     Automation, Accessibility, Screen Recording, Calendar, Reminders, Contacts, Location.
  2. Click Connect when Latchkey asks to connect to relay.latchkey.test (next step).
  3. Click OK on every "would like to control" question that appears while the test data is made.
EOF
say "pairing the test Mac's Latchkey with its private relay"
vm "$BUILD" "cd $VM_DIR && ./e2e-bin prepare"
# Each step below waits on a click in the test Mac's window, so each is tried again until it
# works, for up to WAIT_ROUNDS rounds 20 s apart (nothing waits for a key press here: the script
# runs to the end on its own once the clicks are made; 2026-11-26).
WAIT_ROUNDS=${LATCHKEY_EVAL_IMAGE_WAIT_ROUNDS:-90}
until_ready() { # until_ready WHAT COMMAND: COMMAND inside the test Mac until it succeeds
	local what=$1 i=0
	shift
	until vm "$BUILD" "$*"; do
		i=$((i + 1))
		[ "$i" -lt "$WAIT_ROUNDS" ] || die "$what still not ready after $((WAIT_ROUNDS * 20 / 60)) minutes; fix it in the test Mac's window and run eval-image.sh again."
		say "$what: not yet (above); trying again in 20 s"
		sleep 20
	done
}
say "making each kind of test data once (answer the questions in the test Mac's window)"
until_ready "the test data" "cd $VM_DIR && ./e2e-bin fixture 'fixture notes shopping' 'sweep notes' 'fixture calendar empty' 'sweep calendar' 'fixture reminders empty' 'sweep reminders' 'fixture contacts jordan' 'sweep contacts' 'fixture files todo' 'sweep files'"

say "checking the permissions until every one is approved (the sandbox's own check)"
until_ready "the permissions" "cd $VM_DIR && ./e2e-bin sandbox -checks tools -out /tmp/check.json"
vm "$BUILD" "rm -rf $VM_DIR /tmp/check.json"
"$TART" stop "$BUILD"
if image_exists "$EVAL_IMAGE"; then "$TART" delete "$EVAL_IMAGE"; fi
"$TART" rename "$BUILD" "$EVAL_IMAGE"
say "the test Mac image $EVAL_IMAGE is ready: make -C macos sandbox (after each Mac build), make -C macos evals"
