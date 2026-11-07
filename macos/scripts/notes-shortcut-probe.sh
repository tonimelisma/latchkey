#!/bin/bash
# Probe: can Latchkey set up a shortcut by itself, and do Notes' own actions run through it while
# the Mac is locked? (Notes while locked, Toni 2026-11-05: Shortcuts only if Latchkey sets them
# up itself, otherwise iCloud.com.)
#
#   notes-shortcut-probe.sh build   any screen state: make and sign the shortcut file only
#   notes-shortcut-probe.sh setup   unlocked: make, sign, and add the test shortcut (presses
#                                   "Add Shortcut" itself), then check `shortcuts list` has it
#   notes-shortcut-probe.sh run     any screen state: run it, check Notes has the note
#   notes-shortcut-probe.sh sweep   delete the test note (any state) and the test shortcut
#                                   (unlocked: through Shortcuts' window), then check none is left
#
# Every item carries the tag "Latchkey check notes-probe". Run it through Latchkey's shell (it
# needs Accessibility and Automation of Notes, System Events, and Shortcuts).
set -euo pipefail

TAG="Latchkey check notes-probe"
WORK="${NOTES_PROBE_DIR:-$(mktemp -d)}"
FILE="$WORK/$TAG.shortcut"

locked() { ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked | grep -q '<true/>'; }
has_shortcut() { shortcuts list | grep -qxF "$TAG"; }
note_count() {
	osascript -e "on run argv" -e 'tell application "Notes" to count (notes whose name is (item 1 of argv))' -e "end run" "$TAG"
}

build() {
	# One action: Notes' own "Create Note" (CreateNoteLinkAction in Notes' app actions), named by
	# the tag. App actions are written as <bundle id>.<action id> with an AppIntentDescriptor.
	python3 -I - "$WORK/unsigned.shortcut" "$TAG" <<'EOF'
import plistlib, sys
out, tag = sys.argv[1], sys.argv[2]
action = {
    "WFWorkflowActionIdentifier": "com.apple.Notes.CreateNoteLinkAction",
    "WFWorkflowActionParameters": {
        "AppIntentDescriptor": {
            "BundleIdentifier": "com.apple.Notes", "AppIntentIdentifier": "CreateNoteLinkAction",
            "Name": "Notes", "TeamIdentifier": "0000000000",
        },
        "name": tag,
        "contents": tag + " body",
    },
}
wf = {
    "WFWorkflowActions": [action],
    "WFWorkflowClientVersion": "2607",
    "WFWorkflowMinimumClientVersion": 900,
    "WFWorkflowIcon": {"WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": 59511},
    "WFWorkflowImportQuestions": [],
    "WFWorkflowInputContentItemClasses": ["WFStringContentItem"],
    "WFWorkflowTypes": [],
}
with open(out, "wb") as f:
    plistlib.dump(wf, f, fmt=plistlib.FMT_BINARY)
EOF
	shortcuts sign --mode anyone --input "$WORK/unsigned.shortcut" --output "$FILE"
}

press_add() {
	# Shortcuts shows the import sheet; press its "Add Shortcut" button (up to 15 s).
	osascript <<'EOF'
tell application "System Events"
	repeat 60 times
		if exists process "Shortcuts" then
			tell process "Shortcuts"
				repeat with theWindow in windows
					try
						set theButtons to (every button of entire contents of theWindow whose name is "Add Shortcut")
						if (count of theButtons) > 0 then
							click item 1 of theButtons
							return "pressed"
						end if
					end try
				end repeat
			end tell
		end if
		delay 0.25
	end repeat
	return "no Add Shortcut button"
end tell
EOF
}

delete_shortcut() {
	# Open the shortcut's editor, then File > Delete Shortcut (or Edit > Delete) and confirm.
	shortcuts view "$TAG"
	osascript <<'EOF'
tell application "System Events"
	delay 1.5
	tell process "Shortcuts"
		set frontmost to true
		repeat with menuName in {"File", "Edit"}
			try
				set theItems to (every menu item of menu 1 of menu bar item (menuName as text) of menu bar 1 whose name starts with "Delete")
				if (count of theItems) > 0 then
					click item 1 of theItems
					delay 0.75
					repeat with theWindow in windows
						try
							set theButtons to (every button of entire contents of theWindow whose name is "Delete")
							if (count of theButtons) > 0 then click item 1 of theButtons
						end try
					end repeat
					return "deleted"
				end if
			end try
		end repeat
	end tell
	return "no Delete menu item"
end tell
EOF
}

case "${1:-}" in
build)
	build
	echo "signed: $FILE"
	;;
setup)
	if locked; then echo "the Mac is locked: setup needs it unlocked" >&2; exit 2; fi
	build
	echo "signed: $FILE"
	open "$FILE"
	echo "import sheet: $(press_add)"
	for _ in $(seq 40); do has_shortcut && break; sleep 0.25; done
	if has_shortcut; then echo "PASS setup: \"$TAG\" is in shortcuts list"; else echo "FAIL setup: not in shortcuts list" >&2; exit 1; fi
	;;
run)
	echo "locked: $(locked && echo yes || echo no)"
	before=$(note_count)
	if ! out=$(shortcuts run "$TAG" 2>&1); then echo "FAIL run: $out" >&2; exit 1; fi
	for _ in $(seq 40); do [ "$(note_count)" -gt "$before" ] && break; sleep 0.25; done
	after=$(note_count)
	if [ "$after" -gt "$before" ]; then echo "PASS run: Notes made \"$TAG\" ($before -> $after)"; else echo "FAIL run: no note made (shortcut said: $out)" >&2; exit 1; fi
	;;
sweep)
	osascript -e "on run argv" -e 'tell application "Notes" to delete (notes whose name is (item 1 of argv))' -e "end run" "$TAG" || true
	if has_shortcut; then
		if locked; then echo "the shortcut stays until an unlock (Shortcuts' window is needed)" >&2; else echo "shortcut: $(delete_shortcut)"; fi
	fi
	sleep 1
	left_notes=$(note_count)
	left_shortcut=$(has_shortcut && echo 1 || echo 0)
	echo "left: notes=$left_notes shortcut=$left_shortcut"
	[ "$left_notes" = 0 ] && [ "$left_shortcut" = 0 ] || exit 1
	;;
*)
	sed -n 2,14p "$0"
	exit 2
	;;
esac
