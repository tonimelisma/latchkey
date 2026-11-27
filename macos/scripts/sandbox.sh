#!/bin/bash
# The sandbox Mac (spec 016 FR-1605, FR-1606, plan D3): the working tree's Mac app, checked
# against the real Mac apps with test data, in a Tart virtual Mac. Run it from a clone on an
# Apple silicon Mac with Tart, Go, Xcode and XcodeGen, and the image from eval-image.sh:
#
#   make -C macos sandbox        (macos/scripts/sandbox.sh [--checks a,b])
#   make -C macos sandbox-stop   (macos/scripts/sandbox.sh --stop): stops and deletes the copy
#
# It builds the Release app from the working tree, signed with the sandbox's own self-signed
# identity (made once in a keychain of its own, never the login keychain; never Local.xcconfig, an
# Apple team or a developer certificate), starts a copy of the image without a window (or reuses the one this checkout
# started), installs the build in it, and runs `e2e sandbox` there: every capability the image
# can exercise, with its test data, through the copy's private relay and a real MCP client, and
# the connection checks. Nothing appears on this Mac's screen, and nothing of this Mac goes in.
# The result: e2e-results/sandbox-<build>-<time>.json, a line per check, and each phase's time.
set -eu
. "$(dirname "$0")/eval-lib.sh"

CHECKS=all
STOP=0
while [ $# -gt 0 ]; do
	case "$1" in
	--stop) STOP=1 ;;
	--checks)
		[ $# -ge 2 ] || die "--checks needs a list (like files,notes)"
		CHECKS=$2
		shift
		;;
	-h | --help)
		sed -n '2,15p' "$0"
		exit 0
		;;
	*) die "unknown option $1 (sandbox.sh takes --checks LIST or --stop)" ;;
	esac
	shift
done
case "$CHECKS" in *[!a-z,-]*) die "--checks takes names like files,notes" ;; esac

RESULTS=$REPO_ROOT/e2e-results
STATE=$RESULTS/.sandbox-vm

need_tools
if [ "$STOP" = 1 ]; then
	if [ -f "$STATE" ]; then
		name=$(cat "$STATE")
		"$TART" stop "$name" >/dev/null 2>&1 || true
		"$TART" delete "$name" >/dev/null 2>&1 || true
		rm -f "$STATE"
		say "stopped and deleted the sandbox copy $name"
	else
		say "no sandbox copy from this checkout is running"
	fi
	exit 0
fi
need_build_tools
image_exists "$EVAL_IMAGE" || die "no test Mac image $EVAL_IMAGE yet: run macos/scripts/eval-image.sh once first."

mkdir -p "$RESULTS"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM
caffeinate -i -w $$ >/dev/null 2>&1 &

TIMES=""
phase_start=$(date +%s)
phase() { # phase NAME: the time since the last one, under NAME
	local now
	now=$(date +%s)
	TIMES="$TIMES$1 $((now - phase_start)) s, "
	phase_start=$now
}

sandbox_identity
sandbox_build
phase build

# This checkout's copy: one name per clone, kept in e2e-results/ (ignored by git).
VM=$EVAL_IMAGE-sandbox-$(printf '%s' "$REPO_ROOT" | cksum | cut -d' ' -f1)
start_copy() {
	nohup "$TART" run --no-graphics "$VM" >"$RESULTS/.sandbox-run.log" 2>&1 &
	wait_vm "$VM"
}
if [ -f "$STATE" ] && [ "$(cat "$STATE")" = "$VM" ] && image_exists "$VM"; then
	if "$TART" exec "$VM" /usr/bin/true >/dev/null 2>&1; then
		say "reusing the running sandbox copy $VM"
	else
		say "starting the sandbox copy $VM again, without a window"
		start_copy
	fi
else
	say "copying the test Mac ($EVAL_IMAGE → $VM) and starting it without a window"
	if image_exists "$VM"; then vm_remove "$VM"; fi
	"$TART" clone "$EVAL_IMAGE" "$VM"
	printf '%s\n' "$VM" >"$STATE"
	start_copy
fi
phase start

say "installing the build in the sandbox copy"
install_latchkey_build "$VM" "$SANDBOX_APP"
build_e2e "$WORK/e2e"
push_run "$VM" "$WORK/e2e"
phase install

say "running the checks in the sandbox copy (test data made and removed by each check)"
status=0
vm "$VM" "cd $VM_DIR && ./e2e-bin sandbox -build '$SANDBOX_LABEL' -checks '$CHECKS' -out sandbox.json" || status=$?
phase checks
OUT=$RESULTS/sandbox-$SANDBOX_LABEL-$(date +%Y%m%d-%H%M%S).json
if ! "$TART" exec "$VM" /bin/zsh -lc "cat $VM_DIR/sandbox.json" >"$OUT" 2>/dev/null || [ ! -s "$OUT" ]; then
	rm -f "$OUT"
	die "the run left no result (exit $status); the sandbox copy's output is above."
fi
say "time: ${TIMES%, } (spec 016 FR-1612: first run under 5 minutes, later ones under 2)"
say "result: $OUT"
say "the sandbox copy $VM stays running for the next run; make -C macos sandbox-stop deletes it"
[ "$status" = 0 ] || die "checks failed (exit $status); what each found is above and in $OUT."
