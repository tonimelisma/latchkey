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

# reqhex PATH: the code's designated requirement, compiled, as hex (what macOS stores in a row:
# a row without it was asked about again, the first image run, 2026-11-26).
reqhex() {
	local r t
	r=$(codesign -dr - "$1" 2>/dev/null | sed -n 's/^designated => //p')
	[ -n "$r" ] || { echo "no designated requirement for $1" >&2; return 1; }
	t=$(mktemp)
	print -r -- "$r" | csreq -r- -b "$t"
	xxd -p "$t" | tr -d '\n'
	rm -f "$t"
}
csreq=$(reqhex "$app")
# macOS files a program by its real path, not a symlink's (Homebrew's /opt/homebrew/bin link:
# the first image run asked about the agent although a row for the link existed).
agent=$(ps axo comm= | grep -m1 '/tart-guest-agent$' || true)
[ -z "$agent" ] || agent=${agent:A}

# row DB SERVICE CLIENT CLIENT_TYPE CSREQ_HEX [TARGET TARGET_CSREQ_HEX]: allowed (2), set by the
# system (4).
row() {
	local db=$1 service=$2 client=$3 type=$4 req=$5 target=${6:-UNUSED} treq=${7:-} blob=NULL tblob=NULL
	[ -n "$req" ] && blob="X'$req'"
	[ -n "$treq" ] && tblob="X'$treq'"
	sqlite3 "$db" "INSERT OR REPLACE INTO access
		(service, client, client_type, auth_value, auth_reason, auth_version, csreq, indirect_object_identifier_type, indirect_object_identifier, indirect_object_code_identity, flags)
		VALUES ('$service', '$client', $type, 2, 4, 1, $blob, 0, '$target', $tblob, 0);"
}
for s in kTCCServiceSystemPolicyAllFiles kTCCServiceAccessibility kTCCServiceScreenCapture kTCCServicePostEvent kTCCServiceListenEvent; do
	row "$system_db" "$s" "$id" 0 "$csreq"
done
for s in kTCCServiceAddressBook kTCCServiceCalendar kTCCServiceReminders kTCCServiceSystemPolicyDownloadsFolder kTCCServiceSystemPolicyDocumentsFolder kTCCServiceSystemPolicyDesktopFolder; do
	row "$user_db" "$s" "$id" 0 "$csreq"
done
typeset -A targets=(
	com.apple.Notes /System/Applications/Notes.app
	com.apple.MobileSMS /System/Applications/Messages.app
	com.apple.mail /System/Applications/Mail.app
	com.apple.Safari /Applications/Safari.app
	com.apple.systemevents "/System/Library/CoreServices/System Events.app"
	com.apple.finder /System/Library/CoreServices/Finder.app
	com.apple.iCal /System/Applications/Calendar.app
	com.apple.reminders /System/Applications/Reminders.app
	com.apple.AddressBook /System/Applications/Contacts.app
)
clients=(/usr/bin/osascript)
[ -z "$agent" ] || clients+=("$agent")
# The test data's AppleScript adds to Calendar, Reminders and Contacts: macOS asks for the
# sender's own access to them too ("tart-guest-agent would like to add to your Calendar", the
# third image run).
for c in $clients; do
	for s in kTCCServiceCalendar kTCCServiceReminders kTCCServiceAddressBook; do
		row "$user_db" "$s" "$c" 1 "$(reqhex "$c")"
	done
	# The sandbox's checks read what macOS's Accessibility sees (which Finder sidebar row is
	# selected, computer-sidebar-row, 2026-11-27): System Events answers that only to a program
	# allowed Accessibility. In the test Mac only.
	row "$system_db" kTCCServiceAccessibility "$c" 1 "$(reqhex "$c")"
done
for target tpath in "${(@kv)targets}"; do
	treq=$(reqhex "$tpath") || continue
	row "$user_db" kTCCServiceAppleEvents "$id" 0 "$csreq" "$target" "$treq"
	for c in $clients; do
		row "$user_db" kTCCServiceAppleEvents "$c" 1 "$(reqhex "$c")" "$target" "$treq"
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
echo "granted $id and the test data's AppleScript (osascript${agent:+, $agent})"
