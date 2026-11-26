#!/bin/zsh
# Runs as root INSIDE the test Mac (a Tart copy with System Integrity Protection off, as the
# cirruslabs base images are), never on a real Mac: eval-lib.sh's vm_grant_permissions sends it
# there. It grants the installed /Applications/Latchkey.app the macOS permissions its setup asks
# a person to approve, by writing them into macOS's permission databases (TCC), as the base image
# itself does for osascript and Tart's guest agent; and lets the test data's AppleScript (run by
# Tart's guest agent through osascript) control the apps it fills. Latchkey's rows carry the
# installed build's designated requirement, so they hold only for builds signed like it (the
# sandbox's identity). Then Safari's "Allow JavaScript from Apple Events", and macOS's permission
# daemons start again to read the rows. (2026-11-26: the first image needed a person to click
# about twenty approvals in the test Mac's window; spec 016 FR-1606 wants nothing of the owner's.)
set -eu
user=${1:?the test Mac user}
app=/Applications/Latchkey.app
csrutil status | grep -q 'status: disabled' ||
	{ echo "System Integrity Protection is on in this Mac: refusing (only a test Mac has it off)" >&2; exit 1; }
[ -d "$app" ] || { echo "no $app" >&2; exit 1; }
home=$(dscl . -read "/Users/$user" NFSHomeDirectory | awk '{print $2}')
system_db="/Library/Application Support/com.apple.TCC/TCC.db"
user_db="$home/Library/Application Support/com.apple.TCC/TCC.db"
id=$(defaults read "$app/Contents/Info" CFBundleIdentifier)
req=$(codesign -dr - "$app" 2>/dev/null | sed -n 's/^designated => //p')
[ -n "$req" ] || { echo "no designated requirement for $app" >&2; exit 1; }
t=$(mktemp -d)
print -r -- "$req" | csreq -r- -b "$t/req.bin"
csreq=$(xxd -p "$t/req.bin" | tr -d '\n')
rm -rf "$t"
agent=$(ps axo comm= | grep -m1 '/tart-guest-agent$' || true)

# row DB SERVICE CLIENT CLIENT_TYPE CSREQ_HEX TARGET: allowed (2), set by the system (4).
row() {
	local db=$1 service=$2 client=$3 type=$4 req=$5 target=${6:-UNUSED} blob=NULL
	[ -n "$req" ] && blob="X'$req'"
	sqlite3 "$db" "INSERT OR REPLACE INTO access
		(service, client, client_type, auth_value, auth_reason, auth_version, csreq, indirect_object_identifier_type, indirect_object_identifier, flags)
		VALUES ('$service', '$client', $type, 2, 4, 1, $blob, 0, '$target', 0);"
}
for s in kTCCServiceSystemPolicyAllFiles kTCCServiceAccessibility kTCCServiceScreenCapture kTCCServicePostEvent kTCCServiceListenEvent; do
	row "$system_db" "$s" "$id" 0 "$csreq"
done
for s in kTCCServiceAddressBook kTCCServiceCalendar kTCCServiceReminders kTCCServiceSystemPolicyDownloadsFolder kTCCServiceSystemPolicyDocumentsFolder kTCCServiceSystemPolicyDesktopFolder; do
	row "$user_db" "$s" "$id" 0 "$csreq"
done
targets=(com.apple.Notes com.apple.MobileSMS com.apple.mail com.apple.Safari com.apple.systemevents com.apple.finder com.apple.iCal com.apple.reminders com.apple.AddressBook)
for target in $targets; do
	row "$user_db" kTCCServiceAppleEvents "$id" 0 "$csreq" "$target"
	row "$system_db" kTCCServiceAppleEvents "$id" 0 "$csreq" "$target"
	for c in /usr/bin/osascript $agent; do
		row "$user_db" kTCCServiceAppleEvents "$c" 1 "" "$target"
		row "$system_db" kTCCServiceAppleEvents "$c" 1 "" "$target"
	done
done
chown "$user" "$user_db"

# Screen recording's second question ("… is requesting to bypass the system private window
# picker"), asked at a program's first screenshot: answered for Latchkey and Tart's agent.
approvals="$home/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals"
mkdir -p "${approvals:h}"
for p in "$app/Contents/MacOS/Latchkey" $agent; do
	defaults write "$approvals" "$p" -date "4000-01-01 00:00:00 +0000"
done
chown -R "$user" "${approvals:h}"

# Safari: the developer features and "Allow JavaScript from Apple Events" (Safari keeps them in
# its container; macOS lets only a person or root with System Integrity Protection off write
# there).
safari="$home/Library/Containers/com.apple.Safari/Data/Library/Preferences/com.apple.Safari"
mkdir -p "${safari:h}"
for k in AllowJavaScriptFromAppleEvents IncludeDevelopMenu WebKitDeveloperExtrasEnabledPreferenceKey \
	DeveloperMenuVisibility WebKitPreferences.developerExtrasEnabled; do
	defaults write "$safari" "$k" -bool true
done
chown -R "$user" "$home/Library/Containers/com.apple.Safari" 2>/dev/null || true
killall -u "$user" cfprefsd 2>/dev/null || true

killall tccd 2>/dev/null || true
echo "granted $id (requirement: $req)"
