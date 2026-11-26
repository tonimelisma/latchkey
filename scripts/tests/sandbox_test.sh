#!/bin/bash
# Tests for macos/scripts/sandbox.sh (spec 016 FR-1605, FR-1606, plan D3): it refuses with the
# fix in plain words when something it needs is missing, before touching anything; it makes the
# sandbox's signing identity once and reuses it; it builds from a copy without Local.xcconfig,
# never with a team; it starts a copy of the image or reuses the running one; --stop deletes it;
# nothing personal reaches its output. Tart, Xcode, XcodeGen, the keychain, openssl and uname
# are stand-ins on PATH; the script runs in a throwaway clone of its own.
# Run: scripts/tests/sandbox_test.sh (or `make -C relay script-tests`).
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
has() { if printf '%s' "$2" | grep -q -- "$3"; then ok "$1"; else bad "$1 (wanted '$3' in: $2)"; fi; }
lacks() { if printf '%s' "$2" | grep -q -- "$3"; then bad "$1 (found '$3' in: $2)"; else ok "$1"; fi; }
count() { grep -c -- "$2" "$1" 2>/dev/null || true; }

# A clone of its own: the scripts, a macos/ with a Local.xcconfig holding private values, and
# the relay files push_run sends.
repo=$work/repo
mkdir -p "$repo/macos/scripts" "$repo/macos/Config" "$repo/macos/App" "$repo/relay/e2e/tasks/files"
cp "$root/macos/scripts/sandbox.sh" "$root/macos/scripts/eval-lib.sh" "$repo/macos/scripts/"
cp "$root/.gitignore" "$repo/.gitignore"
echo 'name: Latchkey' >"$repo/macos/project.yml"
echo '#include? "Local.xcconfig"' >"$repo/macos/Config/Base.xcconfig"
echo 'let x = 1' >"$repo/macos/App/A.swift"
echo '{}' >"$repo/relay/e2e/tasks/files/t.json"
git -C "$repo" init -q
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@example.com commit -qm init
private_team=SECRETTEAM1
private_relay=relay.private.invalid
printf 'DEVELOPMENT_TEAM = %s\nLATCHKEY_DEFAULT_RELAY_HOST = %s\n' "$private_team" "$private_relay" >"$repo/macos/Config/Local.xcconfig"
sandbox=$repo/macos/scripts/sandbox.sh

bin=$work/bin
mkdir -p "$bin" "$work/running"
touch "$work/vms"
cat >"$bin/uname" <<'S'
#!/bin/sh
case "$1" in -s) echo "${FAKE_UNAME_S:-Darwin}" ;; -m) echo "${FAKE_UNAME_M:-arm64}" ;; *) echo Darwin ;; esac
S
# tart: images are FAKE_IMAGES plus the copies it made; `run` marks a copy running; `exec` works
# only on a running copy, prints FAKE_RESULT for the result and fails the checks with
# FAKE_CHECKS_EXIT.
cat >"$bin/tart" <<'S'
#!/bin/bash
echo "$*" >>"$W/tart.log"
case "$1" in
list) for i in ${FAKE_IMAGES:-}; do echo "$i"; done; cat "$W/vms" ;;
clone) echo "$3" >>"$W/vms" ;;
delete) grep -vx "$2" "$W/vms" >"$W/vms.new"; mv "$W/vms.new" "$W/vms"; rm -f "$W/running/$2" ;;
run) touch "$W/running/${*: -1}" ;;
stop) rm -f "$W/running/$2" ;;
exec)
	[ "${2:-}" = --help ] && exit 0
	shift
	stdin=0
	[ "$1" = -i ] && { stdin=1; shift; }
	[ -e "$W/running/$1" ] || exit 1
	[ "$stdin" = 0 ] || cat >/dev/null # like tart: stdin only with -i
	case "$*" in
	*"e2e-bin sandbox"*) echo "PASS files (1.0 s)"; exit "${FAKE_CHECKS_EXIT:-0}" ;;
	*"codesign -dvvv"*) echo abcdef0123456789 ;;
	*"dump-keychain"*) cat <<'K'
keychain: "/Users/admin/Library/Keychains/login.keychain-db"
class: "genp"
attributes:
    0x00000007 <blob>="net.melisma.latchkey"
    "acct"<blob>="pairing"
    "svce"<blob>="net.melisma.latchkey"
keychain: "/Users/admin/Library/Keychains/login.keychain-db"
class: "genp"
attributes:
    "acct"<blob>="someone"
    "svce"<blob>="com.example.other"
keychain: "/Users/admin/Library/Keychains/login.keychain-db"
class: "genp"
attributes:
    0x00000007 <blob>="net.melisma.latchkey"
    "acct"<blob>="activity-log-key"
    "svce"<blob>="net.melisma.latchkey"
K
		;;
	*"set-generic-password-partition-list"*) echo "$*" >>"$W/partition.log" ;;
	*"cat "*sandbox.json*) printf '%s\n' "${FAKE_RESULT-{\"kind\":\"sandbox\"}}" ;;
	esac
	exit 0 ;;
esac
S
# security: create-keychain makes the keychain file, import puts the identity in it, the saved
# password is there once added; find-identity (which lists every identity, the owner's too)
# answers with a private one, and is logged.
cat >"$bin/security" <<'S'
#!/bin/sh
echo "$*" >>"$W/security.log"
last=$(eval echo "\${$#}")
case "$1" in
find-identity) echo '  1) ABCDEF "Apple Development: Owner (SECRETTEAM1)"'; exit 0 ;;
create-keychain) echo kc >"$last" ;;
import) [ -e "$4" ] && touch "$W/identity" ;;
find-certificate) [ -e "$W/identity" ] || exit 44; echo 'SHA-1 hash: 0123456789ABCDEF0123456789ABCDEF01234567' ;;
add-generic-password) touch "$W/saved-pw" ;;
find-generic-password) [ -e "$W/saved-pw" ] && echo 0123456789abcdef0123456789abcdef ;;
delete-keychain) rm -f "$last" ;;
*) exit 0 ;;
esac
S
# codesign: records what it signs and with what; file says what is a program.
cat >"$bin/codesign" <<'S'
#!/bin/sh
echo "$*" >>"$W/codesign.log"
S
cat >"$bin/file" <<'S'
#!/bin/sh
case "$2" in *.txt) echo "ASCII text" ;; *) echo "Mach-O 64-bit executable arm64" ;; esac
S
# openssl: makes the files it is asked for.
cat >"$bin/openssl" <<'S'
#!/bin/sh
echo "$*" >>"$W/openssl.log"
[ "$1" = rand ] && { echo 0123456789abcdef0123456789abcdef; exit 0; }
while [ $# -gt 0 ]; do case "$1" in -out | -keyout) echo x >"$2"; shift ;; esac; shift; done
S
# xcodegen and xcodebuild: record what they see; the build makes a Latchkey.app.
cat >"$bin/xcodegen" <<'S'
#!/bin/sh
echo "xcodegen $* in $PWD" >>"$W/build.log"
[ -e Config/Local.xcconfig ] && echo LOCAL_SEEN >>"$W/build.log"
mkdir -p Latchkey.xcodeproj
S
cat >"$bin/xcodebuild" <<'S'
#!/bin/sh
[ "$1" = -version ] && { echo "Xcode 27.2"; exit 0; }
for a in "$@"; do echo "arg:$a" >>"$W/build.log"; done
while [ $# -gt 0 ]; do
	case "$1" in
	-derivedDataPath) a="$2/Build/Products/Release/Latchkey.app/Contents"; mkdir -p "$a/MacOS" "$a/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS"; for x in MacOS/Latchkey MacOS/LatchkeyHelper Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer; do echo bin >"$a/$x"; chmod +x "$a/$x"; done; echo t >"$a/notes.txt"; chmod +x "$a/notes.txt"; shift ;;
	-project) [ -e "$(dirname "$2")/Config/Local.xcconfig" ] && echo LOCAL_SEEN >>"$W/build.log"; shift ;;
	esac
	shift
done
S
cat >"$bin/go" <<'S'
#!/bin/sh
while [ $# -gt 0 ]; do [ "$1" = -o ] && { echo bin >"$2"; shift; }; shift; done
S
printf '#!/bin/sh\necho "$*" >>"$W/lsregister.log"\n' >"$bin/lsregister"
printf '#!/bin/sh\nexit 0\n' >"$bin/caffeinate"
chmod +x "$bin"/*
export W=$work LSREGISTER=$bin/lsregister LATCHKEY_SANDBOX_KEYCHAIN=$work/latchkey-sandbox.keychain-db
run() { PATH="$bin:/usr/bin:/bin" "$@" 2>&1; }
quiet() { : >"$work/tart.log"; : >"$work/security.log"; : >"$work/build.log"; : >"$work/codesign.log"; }

# Refusals, before anything is touched.
quiet
has "--help says what it does" "$(run "$sandbox" --help)" "sandbox-stop"
has "an unknown option is refused" "$(run "$sandbox" --chekcs files)" "unknown option --chekcs"
has "--checks takes only names" "$(run "$sandbox" --checks 'files;rm -rf ~')" "takes names like files,notes"
has "not a Mac: says so" "$(FAKE_UNAME_S=Linux run "$sandbox")" "runs on a Mac"
has "an Intel Mac: says Apple silicon" "$(FAKE_UNAME_M=x86_64 run "$sandbox")" "Apple silicon"
notart=$work/notart
mkdir -p "$notart"
for f in "$bin"/*; do [ "$(basename "$f")" = tart ] || cp "$f" "$notart/"; done
has "no Tart: says how to install it" "$(PATH="$notart:/usr/bin:/bin" "$sandbox" 2>&1)" "Tart isn't installed"
# Regression (2026-11-26): Tart moved from cirruslabs/cli to the openai/tools tap; the old name
# installs nothing.
has "no Tart: names the tap it is in now" "$(PATH="$notart:/usr/bin:/bin" "$sandbox" 2>&1)" "brew install openai/tools/tart"
noxcode=$work/noxcode
mkdir -p "$noxcode"
for f in "$bin"/*; do [ "$(basename "$f")" = xcodebuild ] || cp "$f" "$noxcode/"; done
# Regression (2026-11-26): every Mac has /usr/bin/xcodebuild, a stub that fails without Xcode,
# so "is it on PATH" said yes on a Mac without Xcode.
printf '#!/bin/sh\necho "xcode-select: error: tool xcodebuild requires Xcode" >&2\nexit 1\n' >"$noxcode/xcodebuild"
chmod +x "$noxcode/xcodebuild"
has "no Xcode: says so" "$(PATH="$noxcode:/usr/bin:/bin" "$sandbox" 2>&1)" "Xcode isn't installed"
has "no image yet: says to run eval-image.sh" "$(run "$sandbox")" "run macos/scripts/eval-image.sh once first"
if grep -qE '^(clone|run|delete|stop)' "$work/tart.log" || [ -s "$work/security.log" ] || [ -s "$work/build.log" ]; then
	bad "nothing was built, signed, copied or started before the checks passed"
else
	ok "nothing was built, signed, copied or started before the checks passed"
fi

# The first run: identity made, build, a new copy, the checks, the result.
quiet
out=$(FAKE_IMAGES=latchkey-eval run "$sandbox")
st=$?
[ "$st" = 0 ] && ok "the first run passes" || bad "the first run passes (exit $st): $out"
has "it says it makes the signing identity" "$out" "making the sandbox's own signing identity"
[ "$(count "$work/security.log" "^import .* -k $work/latchkey-sandbox.keychain-db ")" = 1 ] && ok "the identity is imported once, into the sandbox's own keychain" || bad "the identity is imported once into its keychain ($(cat "$work/security.log"))"
grep -q "^create-keychain -p [0-9a-f]* $work/latchkey-sandbox.keychain-db$" "$work/security.log" && ok "the sandbox's keychain is made with a random password" || bad "create-keychain ($(cat "$work/security.log"))"
grep -q '^add-generic-password -U -a .* -s latchkey-sandbox-keychain -w ' "$work/security.log" && ok "its password is saved for later runs" || bad "password saved"
# Regression (first local run, 2026-11-26): the identity was imported into the login keychain and
# trusted there, which opens macOS's password dialog on the owner's screen.
if grep -qE '^(add-trusted-cert|remove-trusted-cert|trust-settings-import|list-keychains|default-keychain)' "$work/security.log"; then
	bad "nothing is trusted and the keychain list isn't changed ($(cat "$work/security.log"))"
else ok "nothing is trusted and the keychain list isn't changed"; fi
if grep -q 'login.keychain' "$work/security.log"; then bad "the login keychain is never named"; else ok "the login keychain is never named"; fi
grep -q '^arg:CODE_SIGN_IDENTITY=-$' "$work/build.log" && ok "Xcode signs ad hoc" || bad "Xcode signs ad hoc"
hash=0123456789ABCDEF0123456789ABCDEF01234567
if grep -v -- "--sign $hash --keychain $work/latchkey-sandbox.keychain-db " "$work/codesign.log" | grep -q -- '--sign'; then
	bad "every piece is signed with the sandbox's identity from its keychain ($(cat "$work/codesign.log"))"
else ok "every piece is signed with the sandbox's identity from its keychain"; fi
grep -q 'preserve-metadata=identifier,entitlements,flags,runtime' "$work/codesign.log" && ok "the signing keeps each piece's entitlements and hardened runtime" || bad "preserve-metadata"
signed=$(grep -- '--sign' "$work/codesign.log" | sed 's/.* //')
inst=$(printf '%s\n' "$signed" | grep -n 'Installer$' | cut -d: -f1)
xpc=$(printf '%s\n' "$signed" | grep -n 'Installer.xpc$' | cut -d: -f1)
fw=$(printf '%s\n' "$signed" | grep -n 'Sparkle.framework$' | cut -d: -f1)
appl=$(printf '%s\n' "$signed" | grep -n 'Latchkey.app$' | cut -d: -f1)
total=$(printf '%s\n' "$signed" | wc -l | tr -d ' ')
[ -n "$inst" ] && [ -n "$xpc" ] && [ -n "$fw" ] && [ "$inst" -lt "$xpc" ] && [ "$xpc" -lt "$fw" ] && [ "$appl" = "$total" ] &&
	ok "pieces are signed innermost first, the app last" || bad "signing order: $signed"
printf '%s\n' "$signed" | grep -q 'MacOS/LatchkeyHelper$' && ok "the helper is signed" || bad "helper signed"
if printf '%s\n' "$signed" | grep -q 'notes.txt'; then bad "only programs are signed"; else ok "only programs are signed"; fi
grep -q -- '--verify --deep --strict .*Latchkey.app$' "$work/codesign.log" && ok "the signed build is verified" || bad "verify"
grep -q '^arg:CODE_SIGN_STYLE=Manual$' "$work/build.log" && ok "manual signing" || bad "manual signing"
grep -q '^arg:DEVELOPMENT_TEAM=$' "$work/build.log" && ok "DEVELOPMENT_TEAM is passed empty" || bad "DEVELOPMENT_TEAM empty"
if grep -q '^arg:DEVELOPMENT_TEAM=.' "$work/build.log"; then bad "DEVELOPMENT_TEAM is never non-empty"; else ok "DEVELOPMENT_TEAM is never non-empty"; fi
grep -q '^arg:SPARKLE_PUBLIC_ED_KEY=$' "$work/build.log" && ok "no update key (the copy never replaces itself with a release)" || bad "no update key"
grep -q '^arg:Release$' "$work/build.log" && ok "the Release configuration" || bad "Release configuration"
if grep -q LOCAL_SEEN "$work/build.log"; then bad "the build never sees Local.xcconfig"; else ok "the build never sees Local.xcconfig"; fi
if grep -rq SECRETTEAM1 "$repo/macos/build" 2>/dev/null; then bad "Local.xcconfig's values are nowhere in the build folder"; else ok "Local.xcconfig's values are nowhere in the build folder"; fi
grep -q '^-u .*Release/Latchkey.app$' "$work/lsregister.log" && ok "the built app is taken out of Launch Services" || bad "lsregister -u ($(cat "$work/lsregister.log" 2>/dev/null))"
[ -e "$repo/macos/build/sandbox/.metadata_never_index" ] && ok "Spotlight stays out of the build folder" || bad "no .metadata_never_index"
if grep -q '^find-identity' "$work/security.log"; then bad "no other identity is ever listed"; else ok "no other identity is ever listed"; fi
vmname=$(cat "$repo/e2e-results/.sandbox-vm" 2>/dev/null)
case "$vmname" in latchkey-eval-sandbox-*) ok "the copy's name is kept in e2e-results/" ;; *) bad "state file holds '$vmname'" ;; esac
grep -q "^clone latchkey-eval $vmname$" "$work/tart.log" && ok "the image is copied" || bad "clone ($(cat "$work/tart.log"))"
grep -q "^run --no-graphics $vmname$" "$work/tart.log" && ok "the copy starts without a window" || bad "run --no-graphics"
grep -q "e2e-bin sandbox -build '[0-9a-f]\{7\}' -checks 'all'" "$work/tart.log" && ok "the checks run with the commit as the build" || bad "e2e sandbox call ($(grep e2e-bin "$work/tart.log"))"
has "a line per check is printed" "$out" "PASS files"
# Regression (first local run, 2026-11-26): a build without an Apple team is known to the
# keychain by its code hash, so each new build was asked for the test Mac's keychain password.
grep -q "cdhash:abcdef0123456789' -s net.melisma.latchkey -a 'pairing'" "$work/partition.log" 2>/dev/null &&
	ok "each new build may read the pairing in the copy's keychain" || bad "keychain partition list ($(cat "$work/partition.log" 2>/dev/null))"
# Regression (the sandbox's second run): the activity log's items asked for the password anyway;
# they are deleted for each new build (a fresh log), never allowed.
if grep -q "activity-log" "$work/partition.log" 2>/dev/null; then bad "the activity log's items aren't allowed"; else ok "the activity log's items aren't allowed"; fi
grep -q 'delete-generic-password -s net.melisma.latchkey -a "$a"' "$work/tart.log" && grep -q 'for a in activity-log-key activity-log-latest' "$work/tart.log" &&
	ok "the activity log's items are deleted for a new build, the pairing kept" || bad "activity log items deleted"
if grep -q "someone" "$work/partition.log" 2>/dev/null; then bad "another app's keychain item is left alone"; else ok "another app's keychain item is left alone"; fi
has "each phase's time is printed" "$out" "time: build [0-9]* s, start [0-9]* s, install [0-9]* s, checks [0-9]* s"
res=$(ls "$repo"/e2e-results/sandbox-*.json 2>/dev/null | head -1)
[ -n "$res" ] && grep -q '"kind":"sandbox"' "$res" && ok "the result is saved in e2e-results/" || bad "result saved ($res)"
for v in SECRETTEAM1 relay.private.invalid "Apple Development"; do lacks "nothing personal printed ($v)" "$out" "$v"; done

# The second run: the identity and the running copy are reused.
quiet
out=$(FAKE_IMAGES=latchkey-eval run "$sandbox" --checks files,notes)
has "a second run reuses the identity" "$out" "using the sandbox's signing identity"
[ "$(count "$work/security.log" '^import')" = 0 ] && ok "no second identity is made" || bad "no second import"
grep -q "^unlock-keychain -p [0-9a-f]* $work/latchkey-sandbox.keychain-db$" "$work/security.log" && ok "a second run unlocks the sandbox's keychain with the saved password" || bad "unlock ($(cat "$work/security.log"))"
has "a second run reuses the running copy" "$out" "reusing the running sandbox copy $vmname"
if grep -qE '^(clone|run)' "$work/tart.log"; then bad "nothing copied or started again"; else ok "nothing copied or started again"; fi
grep -q "\-checks 'files,notes'" "$work/tart.log" && ok "--checks is passed on" || bad "--checks passed on"

# A keychain without its saved password: stopped with the fix, nothing built.
rm -f "$work/saved-pw"
quiet
out=$(FAKE_IMAGES=latchkey-eval run "$sandbox")
has "a keychain whose password is gone: says to delete it" "$out" "has no saved password: delete that file"
[ -s "$work/build.log" ] && bad "nothing built without the identity" || ok "nothing built without the identity"
touch "$work/saved-pw"

# A copy that was stopped is started again, not copied again.
rm -f "$work/running/$vmname"
quiet
out=$(FAKE_IMAGES=latchkey-eval run "$sandbox")
has "a stopped copy is started again" "$out" "starting the sandbox copy $vmname again"
if grep -q '^clone' "$work/tart.log"; then bad "a stopped copy isn't copied again"; else ok "a stopped copy isn't copied again"; fi

# Failing checks: the run fails, and the result is still kept.
rm -f "$repo"/e2e-results/sandbox-*.json
out=$(FAKE_IMAGES=latchkey-eval FAKE_CHECKS_EXIT=1 run "$sandbox")
st=$?
[ "$st" != 0 ] && ok "failed checks fail the run" || bad "failed checks fail the run"
has "it says so" "$out" "checks failed"
ls "$repo"/e2e-results/sandbox-*.json >/dev/null 2>&1 && ok "the result is kept when checks fail" || bad "result kept on failure"

# --stop deletes the copy.
quiet
out=$(FAKE_IMAGES=latchkey-eval run "$sandbox" --stop)
has "--stop says it deleted the copy" "$out" "stopped and deleted the sandbox copy $vmname"
grep -q "^delete $vmname$" "$work/tart.log" && ok "--stop deletes the copy" || bad "--stop deletes ($(cat "$work/tart.log"))"
[ ! -e "$repo/e2e-results/.sandbox-vm" ] && ok "--stop forgets the copy" || bad "state file left"
has "--stop with no copy says so" "$(run "$sandbox" --stop)" "no sandbox copy from this checkout"

# The Makefile has the targets.
grep -q '^sandbox:' "$root/macos/Makefile" && grep -q '^sandbox-stop:' "$root/macos/Makefile" && grep -q '^evals:' "$root/macos/Makefile" &&
	ok "make sandbox, sandbox-stop and evals exist" || bad "macos/Makefile targets"

[ "$fails" -eq 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
