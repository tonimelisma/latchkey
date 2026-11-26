#!/bin/bash
# Shared by eval-image.sh, evals.sh and sandbox.sh (spec 015 plan D5, D6; spec 016 plan D3, D4):
# the test Mac is a Tart virtual Mac on this Mac, reached only with `tart exec` (its guest
# agent), never with this Mac's own data. Anyone with a clone can run these on an Apple silicon
# Mac with Tart and Go (and Xcode with XcodeGen, for a local build).
# Settings (environment):
#   LATCHKEY_EVAL_IMAGE   the prepared image's name (default latchkey-eval)
#   LATCHKEY_EVAL_BASE    the base image (default ghcr.io/cirruslabs/macos-tahoe-base:latest)
#   LATCHKEY_EVAL_VM_PASSWORD  the base image's user password, for sudo inside it (default admin)
#   LATCHKEY_SANDBOX_BUILD_DIR  where the local build is made (default macos/build/sandbox)
#   LATCHKEY_SANDBOX_KEYCHAIN   the keychain for the sandbox's signing identity (default the
#                         login keychain)
#   TART                  the tart program (default: tart on PATH)
# The local build (sandbox_build) is the Release app from the working tree, signed with the
# sandbox's own self-signed identity "Latchkey Sandbox" (made once, on this Mac, by
# sandbox_identity): never Local.xcconfig, an Apple team, or anyone's developer certificate, so
# every build keeps the image's permission grants and any clone builds it the same way.
# Tested by scripts/tests/eval_scripts_test.sh and sandbox_test.sh.

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

# install_latchkey_build VMNAME APP: a local build (sandbox_build) into the test Mac, replacing
# the one there, copied in through `tart exec` like push_run.
install_latchkey_build() {
	local name=$1 app=$2
	[ "$(basename "$app")" = Latchkey.app ] || die "not a Latchkey.app: $app"
	vm "$name" 'osascript -e "tell application id \"net.melisma.latchkey\" to quit" >/dev/null 2>&1 || true
i=0; while pgrep -x Latchkey >/dev/null 2>&1 && [ $i -lt 30 ]; do sleep 0.5; i=$((i+1)); done
pkill -x Latchkey >/dev/null 2>&1 || true; rm -rf /Applications/Latchkey.app'
	(cd "$(dirname "$app")" && tar -cf - Latchkey.app) | "$TART" exec -i "$name" /bin/zsh -c 'cd /Applications && tar -xf -'
	vm "$name" 'open -a /Applications/Latchkey.app'
}

SANDBOX_IDENTITY="Latchkey Sandbox"
SANDBOX_KEYCHAIN=${LATCHKEY_SANDBOX_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}
SANDBOX_BUILD_DIR=${LATCHKEY_SANDBOX_BUILD_DIR:-$REPO_ROOT/macos/build/sandbox}
LSREGISTER=${LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}

# need_build_tools checks for what a local build needs, with the fix in plain words.
need_build_tools() {
	command -v xcodebuild >/dev/null 2>&1 || die "Xcode isn't installed (xcodebuild): install it from the App Store."
	command -v xcodegen >/dev/null 2>&1 || die "XcodeGen isn't installed: brew install xcodegen"
	command -v openssl >/dev/null 2>&1 || die "openssl isn't installed (it comes with macOS)."
	command -v git >/dev/null 2>&1 || die "git isn't installed: xcode-select --install"
}

# sandbox_identity: the sandbox's own code-signing identity in the login keychain, made the
# first time (a self-signed certificate for code signing, trusted for that only), reused after.
# Only this name is ever looked up; no other identity is listed or read.
sandbox_identity() {
	local t
	t=$(mktemp -d)
	if security find-certificate -c "$SANDBOX_IDENTITY" "$SANDBOX_KEYCHAIN" >/dev/null 2>&1; then
		security find-certificate -c "$SANDBOX_IDENTITY" -p "$SANDBOX_KEYCHAIN" >"$t/cert.pem"
		if security verify-cert -q -c "$t/cert.pem" -p codeSign >/dev/null 2>&1; then
			rm -rf "$t"
			say "using the sandbox's signing identity \"$SANDBOX_IDENTITY\""
			return 0
		fi
		say "trusting \"$SANDBOX_IDENTITY\" for code signing (macOS may ask for your login password once)"
		security add-trusted-cert -r trustRoot -p codeSign -k "$SANDBOX_KEYCHAIN" "$t/cert.pem" ||
			{ rm -rf "$t"; die "couldn't trust the sandbox's signing identity."; }
		rm -rf "$t"
		return 0
	fi
	say "making the sandbox's own signing identity \"$SANDBOX_IDENTITY\" in the login keychain (once)"
	cat >"$t/req.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $SANDBOX_IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
	local pw ok=1
	pw=$(openssl rand -hex 16)
	# The new key exists only in $t until it is imported; $t goes whatever happens.
	if ! openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$t/req.cnf" -extensions ext \
		-keyout "$t/key.pem" -out "$t/cert.pem" >/dev/null 2>&1; then
		ok=0
	elif ! openssl pkcs12 -export -inkey "$t/key.pem" -in "$t/cert.pem" -name "$SANDBOX_IDENTITY" -out "$t/id.p12" \
		-passout "pass:$pw" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1; then
		ok=0
	elif ! security import "$t/id.p12" -k "$SANDBOX_KEYCHAIN" -f pkcs12 -P "$pw" -T /usr/bin/codesign >/dev/null; then
		ok=0
	else
		say "trusting it for code signing only (macOS may ask for your login password once; the first build may ask to let codesign use the key: Always Allow)"
		security add-trusted-cert -r trustRoot -p codeSign -k "$SANDBOX_KEYCHAIN" "$t/cert.pem" || ok=0
	fi
	rm -rf "$t"
	[ "$ok" = 1 ] || die "couldn't make the sandbox's signing identity (openssl or security above)."
}

# sandbox_build: the Release app from the working tree, signed with the sandbox's identity, in
# $SANDBOX_BUILD_DIR; sets SANDBOX_APP and SANDBOX_LABEL (the commit, -dirty with changes).
# It builds from a copy of macos/ without git-ignored files, so Local.xcconfig (the owner's team
# and relay) never reaches the build; with no update key, so the copy never replaces itself with
# a release; and the built app is taken out of this Mac's Launch Services, so nothing on this
# Mac opens it in place of the installed Latchkey (they share the Release bundle identifier).
sandbox_build() {
	local src=$SANDBOX_BUILD_DIR/src derived=$SANDBOX_BUILD_DIR/DerivedData
	SANDBOX_LABEL=$(git -C "$REPO_ROOT" describe --always --dirty --abbrev=7 2>/dev/null || echo unknown)
	SANDBOX_LABEL=$(printf '%s' "$SANDBOX_LABEL" | tr -c 'A-Za-z0-9._-' '-')
	mkdir -p "$SANDBOX_BUILD_DIR"
	touch "$SANDBOX_BUILD_DIR/.metadata_never_index" # Spotlight stays out
	rm -rf "$src"
	mkdir -p "$src"
	git -C "$REPO_ROOT/macos" ls-files -z -co --exclude-standard |
		while IFS= read -r -d '' f; do if [ -e "$REPO_ROOT/macos/$f" ]; then printf '%s\0' "$f"; fi; done |
		(cd "$REPO_ROOT/macos" && tar --null -T - -cf -) | (cd "$src" && tar -xf -)
	[ -f "$src/project.yml" ] || die "couldn't copy macos/ for the build."
	[ ! -e "$src/Config/Local.xcconfig" ] || die "the build copy has a Local.xcconfig; it must never be used."
	say "building the Release app ($SANDBOX_LABEL), signed \"$SANDBOX_IDENTITY\""
	(cd "$src" && xcodegen generate --quiet) || die "xcodegen failed."
	xcodebuild -project "$src/Latchkey.xcodeproj" -scheme Latchkey -configuration Release \
		-destination 'generic/platform=macOS' -derivedDataPath "$derived" \
		CODE_SIGN_IDENTITY="$SANDBOX_IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
		PROVISIONING_PROFILE_SPECIFIER= OTHER_CODE_SIGN_FLAGS="--keychain $SANDBOX_KEYCHAIN" \
		SPARKLE_PUBLIC_ED_KEY= LATCHKEY_DEFAULT_RELAY_HOST= build -quiet ||
		die "the build failed (above)."
	SANDBOX_APP=$derived/Build/Products/Release/Latchkey.app
	[ -d "$SANDBOX_APP" ] || die "the build made no Latchkey.app."
	"$LSREGISTER" -u "$SANDBOX_APP" >/dev/null 2>&1 || true
}
