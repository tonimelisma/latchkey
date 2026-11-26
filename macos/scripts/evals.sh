#!/bin/bash
# The eval run (spec 015 FR-1510 to FR-1517, FR-1530; spec 016 FR-1608, plan D4): real Claude
# Code doing the tasks in relay/e2e/tasks with Latchkey's tools in a Tart virtual Mac. Run it in
# Terminal from a clone, on an Apple silicon Mac with Tart, Go and the image from eval-image.sh
# (and Xcode with XcodeGen for the local build):
#
#   make -C macos evals            the working tree's build (signed like the sandbox, sandbox.sh)
#   macos/scripts/evals.sh --release   the newest signed release from GitHub instead
#   macos/scripts/evals.sh --send  also sealed to the developer's key and sent to the developer's
#                                  intake (Latchkey's developer's runs); with either build
#
# It copies the prepared test Mac, starts the copy without a window (nothing appears on this
# Mac's screen, nothing of this Mac goes in), installs the build in it, and has real Claude
# Code, on the subscription token kept in the login keychain, do every task 3 times there, for
# about an hour; then it deletes the copy, whatever happened. Results stay in this clone
# (e2e-results/), reported as pass rates, never a gate. Nothing to approve.
set -eu
. "$(dirname "$0")/eval-lib.sh"

SEND=0
RELEASE=0
for arg in "$@"; do
	case "$arg" in
	--send) SEND=1 ;;
	--release) RELEASE=1 ;;
	-h | --help)
		sed -n '2,16p' "$0"
		exit 0
		;;
	*) die "unknown option $arg (evals.sh takes --release and --send)" ;;
	esac
done
need_tools
[ "$RELEASE" = 1 ] || need_build_tools
image_exists "$EVAL_IMAGE" || die "no test Mac image $EVAL_IMAGE yet: run macos/scripts/eval-image.sh once first."
token=$(claude_token)

RESULTS=$REPO_ROOT/e2e-results
mkdir -p "$RESULTS"
RUN=$EVAL_IMAGE-run-$(date +%Y%m%d-%H%M%S)
WORK=$(mktemp -d)
cleanup() {
	"$TART" stop "$RUN" >/dev/null 2>&1 || true
	"$TART" delete "$RUN" >/dev/null 2>&1 || true
	rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if [ "$RELEASE" = 0 ]; then
	sandbox_identity
	sandbox_build
fi
say "building the e2e program from this clone"
build_e2e "$WORK/e2e"
say "copying the test Mac ($EVAL_IMAGE → $RUN) and starting it without a window"
"$TART" clone "$EVAL_IMAGE" "$RUN"
"$TART" run --no-graphics "$RUN" >"$WORK/run.log" 2>&1 &
caffeinate -i -w $$ &
wait_vm "$RUN"
if [ "$RELEASE" = 1 ]; then
	say "installing the newest Latchkey release in the test Mac"
	say "(the image's permissions and pairing were made with the sandbox's signature; if the run says a permission is missing, that is why: spec 016 plan D3)"
	install_latchkey "$RUN"
else
	say "installing the working tree's build ($SANDBOX_LABEL) in the test Mac"
	install_latchkey_build "$RUN" "$SANDBOX_APP"
fi
push_run "$RUN" "$WORK/e2e"

say "running the checks and the tasks with Claude Code (about an hour)"
status=0
printf '%s\n' "$token" | "$TART" exec -i "$RUN" /bin/zsh -lc \
	"read -r CLAUDE_CODE_OAUTH_TOKEN; export CLAUDE_CODE_OAUTH_TOKEN; unset ANTHROPIC_API_KEY; cd $VM_DIR && ./e2e-bin evals -out result.json" ||
	status=$?
unset token
OUT=$RESULTS/$RUN.json
if ! "$TART" exec "$RUN" /bin/zsh -lc "cat $VM_DIR/result.json" >"$OUT" 2>/dev/null || [ ! -s "$OUT" ]; then
	rm -f "$OUT"
	die "the run left no result (exit $status); the test Mac's output is above."
fi
say "result: $OUT"
if [ "$SEND" = 1 ]; then
	"$WORK/e2e" send "$OUT"
fi
[ "$status" = 0 ] || die "the run stopped early (exit $status); what it found is in $OUT."
