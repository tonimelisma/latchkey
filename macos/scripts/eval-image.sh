#!/bin/bash
# Prepares the test Mac for the weekly eval run, once (spec 015 FR-1512, FR-1513, plan D6). Run it
# in Terminal from a clone, on an Apple silicon Mac with Tart and Go:
#
#   macos/scripts/eval-image.sh
#
# It makes a virtual Mac from a clean base image (none of this Mac's data goes in), installs
# Chrome, Claude Code and the newest Latchkey release in it, a private relay's test certificate,
# and the test data's apps' first runs; asks for the Claude token (from `claude setup-token`) at a
# password prompt and keeps it in this Mac's login keychain; then opens the test Mac's window
# once so the person running it clicks Connect and approves Latchkey's permissions. The image is
# kept as $LATCHKEY_EVAL_IMAGE (latchkey-eval); each weekly run uses a fresh copy of it. Run it
# again after a new macOS or when the weekly run says a permission is missing.
set -eu
. "$(dirname "$0")/eval-lib.sh"

case "${1:-}" in
-h | --help)
	sed -n '2,13p' "$0"
	exit 0
	;;
"") ;;
*) die "unknown option $1 (eval-image.sh takes none)" ;;
esac
need_tools
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

say "the private relay's test certificate and name (only the test Mac trusts and resolves them)"
build_e2e "$WORK/e2e"
push_run "$BUILD" "$WORK/e2e"
vm "$BUILD" "$VM_DIR/e2e-bin prepare -certs" >/dev/null
vm_home=$(vm "$BUILD" 'printf %s "$HOME"')
vm_sudo "$BUILD" "security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain '$vm_home/latchkey-eval-state/ca.pem'"
vm_sudo "$BUILD" "grep -q relay.latchkey.test /etc/hosts || echo '127.0.0.1 relay.latchkey.test' >> /etc/hosts"

if security find-generic-password -s "$TOKEN_SERVICE" >/dev/null 2>&1; then
	say "the Claude token is already in this Mac's login keychain"
else
	echo
	echo "The weekly run uses your Claude subscription. In another Terminal window run:"
	echo "    claude setup-token"
	echo "and paste the token it prints here (it isn't shown, and goes only into this Mac's login keychain)."
	printf 'Token: '
	read -rs token
	echo
	[ -n "$token" ] || die "no token given."
	security add-generic-password -U -a "$USER" -s "$TOKEN_SERVICE" -w "$token"
	unset token
fi

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
say "making each kind of test data once (answer the questions in the test Mac's window)"
vm "$BUILD" "cd $VM_DIR && ./e2e-bin fixture 'fixture notes shopping' 'sweep notes' 'fixture calendar empty' 'sweep calendar' 'fixture reminders empty' 'sweep reminders' 'fixture contacts jordan' 'sweep contacts' 'fixture files todo' 'sweep files'"
printf '\nWhen every permission is approved in the test Mac, press Enter here. '
read -r _

say "checking the permissions"
token=$(security find-generic-password -s "$TOKEN_SERVICE" -w)
if ! printf '%s\n' "$token" | "$TART" exec -i "$BUILD" /bin/zsh -lc "read -r CLAUDE_CODE_OAUTH_TOKEN; export CLAUDE_CODE_OAUTH_TOKEN; cd $VM_DIR && ./e2e-bin weekly -only none -out /tmp/check.json"; then
	unset token
	die "the test Mac isn't ready (above); fix it in its window and run eval-image.sh again."
fi
unset token
vm "$BUILD" "rm -rf $VM_DIR"
"$TART" stop "$BUILD"
if image_exists "$EVAL_IMAGE"; then "$TART" delete "$EVAL_IMAGE"; fi
"$TART" rename "$BUILD" "$EVAL_IMAGE"
say "the test Mac image $EVAL_IMAGE is ready. Each week: macos/scripts/weekly-eval.sh"
