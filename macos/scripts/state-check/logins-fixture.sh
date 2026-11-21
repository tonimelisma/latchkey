#!/bin/bash
# The test sign-in for the screen-state checks' "logins" group (spec 013): a public test site's
# published login (the-internet.herokuapp.com, tomsmith), handed to the installed Latchkey as a
# Passwords export. An import replaces every copy Latchkey holds, so `add` refuses while Latchkey
# holds anything this script didn't leave (the owner's own sign-ins); `remove` leaves Latchkey
# holding none.
#
#   logins-fixture.sh add      before the group
#   logins-fixture.sh remove   after it (always, also when the run failed)
set -euo pipefail

folder="$HOME/Library/Application Support/Latchkey/Sign-in Import"
marker="$HOME/Library/Caches/latchkey-logins-fixture"
header='Title,URL,Username,Password,Notes,OTPAuth'

# The item's last change, from its attributes only (no secret is read, no prompt shows).
changed() {
  { security find-generic-password -s net.melisma.latchkey -a sign-ins 2>/dev/null || true; } |
    sed -n 's/.*"mdat"<timedate>=0x[0-9A-F]*  "\([0-9]*\)Z.*/\1/p'
}

drop() {
  [ -d "$folder" ] || { echo "logins-fixture: Latchkey's import folder isn't there (is Latchkey 0.8.174 or later running?)" >&2; exit 1; }
  local file="$folder/fixture-$$.csv"
  printf '%s\n' "$1" > "$file.part"
  mv "$file.part" "$file"
  for _ in $(seq 1 40); do
    [ -e "$file" ] || return 0
    sleep 0.25
  done
  rm -f "$file"
  echo "logins-fixture: Latchkey didn't take the file in within 10 seconds" >&2
  exit 1
}

case "${1:-}" in
  add)
    now="$(changed)"
    if [ -n "$now" ] && [ "$now" != "$(cat "$marker" 2>/dev/null)" ]; then
      echo "logins-fixture: Latchkey holds sign-ins this script didn't leave (the owner's); not replacing them. logins.sign_in will skip." >&2
      exit 3
    fi
    drop "$header
Latchkey check,https://the-internet.herokuapp.com/login,tomsmith,SuperSecretPassword!,,"
    changed > "$marker"
    echo "logins-fixture: added the test sign-in"
    ;;
  remove)
    now="$(changed)"
    if [ -n "$now" ] && [ "$now" != "$(cat "$marker" 2>/dev/null)" ]; then
      echo "logins-fixture: Latchkey holds sign-ins this script didn't leave; leaving them alone." >&2
      exit 3
    fi
    [ -n "$now" ] || { echo "logins-fixture: nothing to remove"; exit 0; }
    drop "$header"
    changed > "$marker"
    echo "logins-fixture: removed the test sign-in (Latchkey holds none)"
    ;;
  *)
    echo "usage: $0 add|remove" >&2
    exit 2
    ;;
esac
