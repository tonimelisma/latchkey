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
#   LATCHKEY_SANDBOX_KEYCHAIN   the sandbox signing identity's own keychain (default
#                         ~/Library/Keychains/latchkey-sandbox.keychain-db; never the login one)
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
	command -v "$TART" >/dev/null 2>&1 || die "Tart isn't installed: brew install openai/tools/tart (Homebrew asks once to trust that tap: brew trust --formula openai/tools/tart openai/tools/softnet)"
	"$TART" exec --help >/dev/null 2>&1 || die "this Tart has no 'tart exec': update it (brew upgrade tart)."
	command -v go >/dev/null 2>&1 || die "Go isn't installed: brew install go"
}

# claude_token prints the Claude subscription token kept in the login keychain for the evals.
# The first time, in Terminal, it asks for it (from `claude setup-token`) at a password prompt and
# keeps it there; without a terminal it stops and says so. Only the evals use it: the image and
# the sandbox need none (2026-11-26: eval-image.sh asked for it first, so the sandbox waited on a
# token it never uses).
claude_token() {
	local token
	if token=$(security find-generic-password -s "$TOKEN_SERVICE" -w 2>/dev/null) && [ -n "$token" ]; then
		printf '%s\n' "$token"
		return 0
	fi
	[ -t 0 ] || die "no Claude token in the login keychain yet: run macos/scripts/evals.sh once in Terminal; it asks for the token from claude setup-token."
	{
		echo
		echo "The evals use your Claude subscription. In another Terminal window run:"
		echo "    claude setup-token"
		echo "and paste the token it prints here (it isn't shown, and goes only into this Mac's login keychain)."
		printf 'Token: '
	} >&2
	read -rs token
	echo >&2
	[ -n "$token" ] || die "no token given."
	security add-generic-password -U -a "$USER" -s "$TOKEN_SERVICE" -w "$token" || die "couldn't keep the token in the login keychain."
	printf '%s\n' "$token"
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

# push_run VMNAME E2E: the e2e program and the tasks into the test Mac.
push_run() {
	local name=$1 bin=$2
	vm "$name" "rm -rf $VM_DIR && mkdir -p $VM_DIR/e2e"
	"$TART" exec -i "$name" /bin/zsh -c "cat > $VM_DIR/e2e-bin && chmod 700 $VM_DIR/e2e-bin" <"$bin"
	(cd "$REPO_ROOT/relay" && tar -cf - e2e/tasks) | "$TART" exec -i "$name" /bin/zsh -c "cd $VM_DIR && tar -xf -"
}

# vm_grant_permissions VMNAME: the installed build's macOS permissions, written inside the test
# Mac by vm-permissions.zsh (no person approves anything; the base image has System Integrity
# Protection off, which that script checks first).
vm_grant_permissions() {
	local name=$1 user
	user=$(vm "$name" 'id -un')
	"$TART" exec -i "$name" /bin/zsh -c 'cat > /tmp/latchkey-vm-permissions.zsh' <"$REPO_ROOT/macos/scripts/vm-permissions.zsh"
	vm_sudo "$name" "zsh /tmp/latchkey-vm-permissions.zsh '$user'; s=\$?; rm -f /tmp/latchkey-vm-permissions.zsh; exit \$s" ||
		die "couldn't grant Latchkey's permissions in the test Mac (above)."
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
install_latchkey_build() { # VMNAME APP [no-open]
	local name=$1 app=$2
	[ "$(basename "$app")" = Latchkey.app ] || die "not a Latchkey.app: $app"
	vm "$name" 'osascript -e "tell application id \"net.melisma.latchkey\" to quit" >/dev/null 2>&1 || true
i=0; while pgrep -x Latchkey >/dev/null 2>&1 && [ $i -lt 30 ]; do sleep 0.5; i=$((i+1)); done
pkill -x Latchkey >/dev/null 2>&1 || true; rm -rf /Applications/Latchkey.app'
	(cd "$(dirname "$app")" && tar -cf - Latchkey.app) | "$TART" exec -i "$name" /bin/zsh -c 'cd /Applications && tar -xf -'
	vm_keychain_allow "$name"
	[ "${3:-}" = no-open ] || vm_open_latchkey "$name"
}

# vm_open_latchkey VMNAME: starts Latchkey in the test Mac, trying again while its desktop is
# still starting (open fails with -1712 then: the first run, 2026-11-26).
vm_open_latchkey() {
	local i=0
	until vm "$1" 'open -a /Applications/Latchkey.app' 2>/dev/null; do
		i=$((i + 1))
		[ "$i" -lt 30 ] || die "Latchkey didn't start in the test Mac $1 (open failed for a minute)."
		sleep 2
	done
}

# vm_keychain_allow VMNAME: lets the installed build read Latchkey's items in the test Mac's
# login keychain (its pairing, its activity log key). A build signed without an Apple team is
# known to the keychain by its code hash, which every build changes, so without this each new
# sandbox build would be asked for the keychain's password. Uses the test Mac's own password.
vm_keychain_allow() {
	local name=$1 cd accounts a
	cd=$(vm "$name" 'codesign -dvvv /Applications/Latchkey.app 2>&1 | sed -n "s/^CDHash=//p"')
	[ -n "$cd" ] || die "couldn't read the installed build's code hash in the test Mac."
	accounts=$(vm "$name" 'security dump-keychain ~/Library/Keychains/login.keychain-db 2>/dev/null |
		awk "/\"svce\"<blob>=\"net.melisma.latchkey\"/ {s=1} /^keychain:/ {s=0; if (a!=\"\") print a; a=\"\"} s && /\"acct\"<blob>=/ {sub(/.*=\"/, \"\"); sub(/\"$/, \"\"); a=\$0} END {if (s && a!=\"\") print a}"' 2>/dev/null) || true
	for a in $accounts; do
		printf '%s\n' "$VM_PASSWORD" | "$TART" exec -i "$name" /bin/zsh -c "read -r pw; security set-generic-password-partition-list -S 'apple-tool:,apple:,cdhash:$cd' -s net.melisma.latchkey -a '$a' -k \"\$pw\" ~/Library/Keychains/login.keychain-db >/dev/null" ||
			die "couldn't let the new build read its keychain item $a in the test Mac."
	done
}

SANDBOX_IDENTITY="Latchkey Sandbox"
# The sandbox's identity lives in a keychain of its own, never the login keychain
# (sandbox_identity); that keychain's password is a generic password in the login keychain, like
# the Claude token.
SANDBOX_KEYCHAIN=${LATCHKEY_SANDBOX_KEYCHAIN:-$HOME/Library/Keychains/latchkey-sandbox.keychain-db}
SANDBOX_KEYCHAIN_SERVICE=latchkey-sandbox-keychain
SANDBOX_BUILD_DIR=${LATCHKEY_SANDBOX_BUILD_DIR:-$REPO_ROOT/macos/build/sandbox}
LSREGISTER=${LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}

# need_build_tools checks for what a local build needs, with the fix in plain words.
need_build_tools() {
	# /usr/bin/xcodebuild is on every Mac, a stub that fails without Xcode: run it to know.
	xcodebuild -version >/dev/null 2>&1 ||
		die "Xcode isn't installed (xcodebuild -version fails): install it from the App Store, then sudo xcode-select -s /Applications/Xcode.app"
	command -v xcodegen >/dev/null 2>&1 || die "XcodeGen isn't installed: brew install xcodegen"
	command -v openssl >/dev/null 2>&1 || die "openssl isn't installed (it comes with macOS)."
	command -v git >/dev/null 2>&1 || die "git isn't installed: xcode-select --install"
}

# sandbox_identity: the sandbox's own code-signing identity, a self-signed certificate in a
# keychain of its own ($SANDBOX_KEYCHAIN), made the first time and reused after; sets
# SANDBOX_SIGN_HASH (its SHA-1, what codesign is given). It is never put in the login keychain
# and never trusted: codesign signs with an untrusted identity named by its hash, so nothing asks
# for a password and what this Mac trusts doesn't change. (First local run, 2026-11-26: the
# earlier version imported it into the login keychain and trusted it there, which opens macOS's
# password dialog on the owner's screen.) Only this keychain's identity is ever read.
sandbox_identity() {
	local t pw p12pw ok=1
	if [ -f "$SANDBOX_KEYCHAIN" ]; then
		pw=$(security find-generic-password -s "$SANDBOX_KEYCHAIN_SERVICE" -a "$USER" -w 2>/dev/null) ||
			die "the sandbox's keychain $SANDBOX_KEYCHAIN has no saved password: delete that file (it holds only the sandbox's signing identity) and run again."
		security unlock-keychain -p "$pw" "$SANDBOX_KEYCHAIN" >/dev/null 2>&1 ||
			die "couldn't unlock the sandbox's keychain $SANDBOX_KEYCHAIN: delete that file and run again."
		unset pw
		SANDBOX_SIGN_HASH=$(sandbox_hash)
		[ -n "$SANDBOX_SIGN_HASH" ] ||
			die "the sandbox's keychain $SANDBOX_KEYCHAIN holds no \"$SANDBOX_IDENTITY\": delete that file and run again."
		say "using the sandbox's signing identity \"$SANDBOX_IDENTITY\""
		return 0
	fi
	say "making the sandbox's own signing identity \"$SANDBOX_IDENTITY\" in a keychain of its own (once)"
	t=$(mktemp -d)
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
	pw=$(openssl rand -hex 16)
	p12pw=$(openssl rand -hex 16)
	# The new key exists only in $t until it is imported; $t goes whatever happens. The keychain:
	# no auto-lock; codesign may use the key without asking; its password kept for later runs.
	if ! openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$t/req.cnf" -extensions ext \
		-keyout "$t/key.pem" -out "$t/cert.pem" >/dev/null 2>&1; then
		ok=0
	elif ! openssl pkcs12 -export -inkey "$t/key.pem" -in "$t/cert.pem" -name "$SANDBOX_IDENTITY" -out "$t/id.p12" \
		-passout "pass:$p12pw" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1; then
		ok=0
	elif ! security create-keychain -p "$pw" "$SANDBOX_KEYCHAIN" >/dev/null; then
		ok=0
	elif ! security set-keychain-settings "$SANDBOX_KEYCHAIN" ||
		! security import "$t/id.p12" -k "$SANDBOX_KEYCHAIN" -f pkcs12 -P "$p12pw" -T /usr/bin/codesign >/dev/null ||
		! security set-key-partition-list -S apple-tool:,apple: -s -k "$pw" "$SANDBOX_KEYCHAIN" >/dev/null ||
		! security add-generic-password -U -a "$USER" -s "$SANDBOX_KEYCHAIN_SERVICE" -w "$pw"; then
		ok=0
		security delete-keychain "$SANDBOX_KEYCHAIN" >/dev/null 2>&1 || true
	fi
	rm -rf "$t"
	unset pw p12pw
	[ "$ok" = 1 ] || die "couldn't make the sandbox's signing identity (openssl or security above)."
	SANDBOX_SIGN_HASH=$(sandbox_hash)
	[ -n "$SANDBOX_SIGN_HASH" ] || die "the sandbox's new keychain holds no \"$SANDBOX_IDENTITY\"."
}

# sandbox_hash: the SHA-1 of "$SANDBOX_IDENTITY" in the sandbox's keychain (no other is read).
sandbox_hash() {
	security find-certificate -c "$SANDBOX_IDENTITY" -Z "$SANDBOX_KEYCHAIN" 2>/dev/null |
		awk '/^SHA-1 hash:/ {print $3; exit}'
}

# sandbox_sign APP: signs every piece of APP with the sandbox's identity, innermost first, keeping
# what Xcode's ad hoc signature gave each piece (its identifier, entitlements, hardened runtime).
# The designated requirement becomes the identifier and this certificate, so every sandbox build
# keeps the test Mac's permissions.
sandbox_sign() {
	local app=$1 f
	# Deepest path first: loose programs and libraries, then the bundles that hold them.
	find "$app/Contents" \( -type d \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' -o -name '*.appex' -o -name '*.bundle' \) \) -o \
		\( -type f \( -perm -u+x -o -name '*.dylib' \) \) |
		awk -F/ '{print NF "\t" $0}' | sort -rn | cut -f2- |
		while IFS= read -r f; do
			if [ -d "$f" ] || file -b "$f" | grep -q Mach-O; then sandbox_sign_one "$f"; fi
		done || exit 1
	sandbox_sign_one "$app"
	codesign --verify --deep --strict "$app" >/dev/null 2>&1 ||
		die "the signed build doesn't verify (codesign --verify --deep --strict $app)."
}

sandbox_sign_one() {
	codesign --force --sign "$SANDBOX_SIGN_HASH" --keychain "$SANDBOX_KEYCHAIN" --timestamp=none \
		--preserve-metadata=identifier,entitlements,flags,runtime "$1" >/dev/null 2>&1 ||
		die "couldn't sign $1 with the sandbox's identity."
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
		CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
		SPARKLE_PUBLIC_ED_KEY= LATCHKEY_DEFAULT_RELAY_HOST= build -quiet ||
		die "the build failed (above)."
	SANDBOX_APP=$derived/Build/Products/Release/Latchkey.app
	[ -d "$SANDBOX_APP" ] || die "the build made no Latchkey.app."
	# Xcode signs ad hoc (it looks for identities only in the keychain search list, where the
	# sandbox's keychain isn't); then each piece is signed again with the sandbox's identity.
	sandbox_sign "$SANDBOX_APP"
	"$LSREGISTER" -u "$SANDBOX_APP" >/dev/null 2>&1 || true
}
