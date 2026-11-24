#!/bin/bash
# Shared by eval-image.sh and weekly-eval.sh (spec 015 plan D5, D6): the test Mac is a Tart
# virtual Mac on this Mac, reached only with `tart exec` (its guest agent), never with this
# Mac's own data. Anyone with a clone can run these on an Apple silicon Mac with Tart and Go.
# Settings (environment):
#   LATCHKEY_EVAL_IMAGE   the prepared image's name (default latchkey-eval)
#   LATCHKEY_EVAL_BASE    the base image (default ghcr.io/cirruslabs/macos-tahoe-base:latest)
#   LATCHKEY_EVAL_VM_PASSWORD  the base image's user password, for sudo inside it (default admin)
#   TART                  the tart program (default: tart on PATH)
# Tested by scripts/tests/eval_scripts_test.sh.

# shellcheck disable=SC2034 # used by the scripts that source this
EVAL_IMAGE=${LATCHKEY_EVAL_IMAGE:-latchkey-eval}
# shellcheck disable=SC2034
EVAL_BASE=${LATCHKEY_EVAL_BASE:-ghcr.io/cirruslabs/macos-tahoe-base:latest}
VM_PASSWORD=${LATCHKEY_EVAL_VM_PASSWORD:-admin}
TART=${TART:-tart}
# shellcheck disable=SC2034
TOKEN_SERVICE=latchkey-eval-claude-token
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# Inside the test Mac: where a run keeps the e2e program and the tasks.
VM_DIR='$HOME/latchkey-eval-run'

say() { printf '• %s\n' "$*"; }
die() {
	printf 'Stopped: %s\n' "$*" >&2
	exit 1
}

# need_tools checks for what both scripts need, with the fix in plain words.
need_tools() {
	[ "$(uname -s)" = Darwin ] || die "this runs on a Mac (Apple silicon) with Tart; this is $(uname -s)."
	[ "$(uname -m)" = arm64 ] || die "Tart's virtual Macs need Apple silicon."
	command -v "$TART" >/dev/null 2>&1 || die "Tart isn't installed: brew install cirruslabs/cli/tart"
	"$TART" exec --help >/dev/null 2>&1 || die "this Tart has no 'tart exec': update it (brew upgrade tart)."
	command -v go >/dev/null 2>&1 || die "Go isn't installed: brew install go"
}

# image_exists NAME
image_exists() { "$TART" list --quiet 2>/dev/null | grep -qx "$1"; }

# build_e2e OUT: the e2e program for the test Mac (and this Mac: both are darwin/arm64).
build_e2e() {
	(cd "$REPO_ROOT/relay" && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -o "$1" ./cmd/e2e) ||
		die "couldn't build relay/cmd/e2e"
}

# vm VMNAME COMMAND...: a shell command inside the test Mac, as its user.
vm() {
	local name=$1
	shift
	"$TART" exec "$name" /bin/zsh -lc "$*"
}

# vm_sudo VMNAME COMMAND: as root inside the test Mac (the base image's password).
vm_sudo() {
	local name=$1
	shift
	printf '%s\n' "$VM_PASSWORD" | "$TART" exec -i "$name" /usr/bin/sudo -S -p '' /bin/zsh -c "$*"
}

# wait_vm VMNAME: until the guest agent answers (up to 5 minutes).
wait_vm() {
	local i=0
	until "$TART" exec "$1" /usr/bin/true >/dev/null 2>&1; do
		i=$((i + 1))
		[ "$i" -lt 150 ] || die "the test Mac $1 didn't start (no answer from its guest agent in 5 minutes)."
		sleep 2
	done
}

# push_run VMNAME E2E: the e2e program, the tasks and the tool snapshots into the test Mac.
push_run() {
	local name=$1 bin=$2
	vm "$name" "rm -rf $VM_DIR && mkdir -p $VM_DIR/e2e"
	"$TART" exec -i "$name" /bin/zsh -c "cat > $VM_DIR/e2e-bin && chmod 700 $VM_DIR/e2e-bin" <"$bin"
	(cd "$REPO_ROOT/relay" && tar -cf - e2e/tasks e2e/toolsnaps) | "$TART" exec -i "$name" /bin/zsh -c "cd $VM_DIR && tar -xf -"
}

# install_latchkey VMNAME: the newest signed release from GitHub into the test Mac. The same
# signature every time, so the image's permissions and pairing hold (research.md).
install_latchkey() {
	vm "$1" 'set -e; t=$(mktemp -d); curl -fsSL -o "$t/Latchkey.dmg" https://github.com/tonimelisma/latchkey/releases/latest/download/Latchkey.dmg
mnt=$(hdiutil attach -nobrowse -readonly "$t/Latchkey.dmg" | awk -F"\t" "/Volumes/ {print \$NF}" | tail -1)
osascript -e "tell application \"Latchkey\" to quit" >/dev/null 2>&1 || true
sleep 2; rm -rf /Applications/Latchkey.app; cp -R "$mnt/Latchkey.app" /Applications/
hdiutil detach -quiet "$mnt"; rm -rf "$t"; open -a /Applications/Latchkey.app'
}
