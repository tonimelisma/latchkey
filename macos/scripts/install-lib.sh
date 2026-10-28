#!/bin/sh
# The decisions of install.sh, as functions, so they can be tested without installing anything
# (scripts/tests/install_pairing_test.sh, install_checks_test.sh). Sourced, not run.
#
# Why: on 2026-10-24 an update started as "not paired (missing pairing record)" and the installer
# still reported success. An install that loses the pairing must fail, loudly.

# pairing_record [service]: "present" or "absent". Whether the installed app's pairing record is
# in the Keychain, from the item's attributes only: no secret is read (never -w or -g), and
# macOS asks nothing.
pairing_record() {
  if security find-generic-password -s "${1:-net.melisma.latchkey}" -a pairing >/dev/null 2>&1; then
    echo present
  else
    echo absent
  fi
}

# paired_before <the old app's start line, or empty> <pairing record: present|absent>: "yes" or
# "no". The running app's own start line decides ("Started <version>, paired with …" or
# "Started <version>, not paired (<reason>)"); without one (the app wasn't running, or its line
# is gone from the log) a pairing record counts as paired.
paired_before() {
  case "$1" in
    *"not paired"*) echo no ;;
    *"paired with"*) echo yes ;;
    *) if [ "$2" = present ]; then echo yes; else echo no; fi ;;
  esac
}

# install_verdict <paired before: yes|no> <old version> <new version> <the new app's start line>
#   <pairing record now: present|absent> <previous disk image, or empty>
# Prints the result of the install and returns 0, or 1 when the Mac was paired before and the new
# app started not paired.
install_verdict() {
  case "$4" in
    *"not paired"*) ;;
    *)
      echo "install: Latchkey $3 installed and running ($4)"
      return 0
      ;;
  esac
  if [ "$1" != yes ]; then
    echo "install: Latchkey $3 installed and running ($4). It wasn't paired before the install either."
    return 0
  fi
  {
    echo "install: PAIRING LOST. This Mac is no longer connected to its relay."
    echo "install: Latchkey $2 was paired; Latchkey $3 started ${4#*, }."
    if [ "$5" = present ]; then
      echo "install: The pairing record is still in the Keychain, so Latchkey $3 can't read or use it."
    else
      echo "install: The pairing record is no longer in the Keychain."
    fi
    echo "install: Don't pair again yet: pairing writes a new record over whatever is left. Find out why first."
    if [ -n "$6" ]; then
      echo "install: The previous disk image is still there to compare with or go back to: macos/$6"
    else
      echo "install: The previous disk image is no longer in macos/build (only the newest is kept)."
    fi
  } >&2
  return 1
}

# The checks after an install (spec 001 FR-622, 2026-10-27). Each takes the app's own diagnostic
# lines (FR-620), as `log show --style compact` prints them after "] ", and returns 1 with a
# message when the installed app doesn't behave.

# window_verdict <Latchkey windows on screen> <the app's setup line, or empty>: a window is right
# only when the app said why ("Opening setup: missing …"); on a set-up Mac there is none.
window_verdict() {
  case "$2" in
    "Opening setup: "*)
      echo "install: the setup window is open: ${2#Opening setup: }"
      return 0
      ;;
  esac
  if [ "$1" = 0 ]; then
    echo "install: no window open (${2:-no setup decision logged yet})"
    return 0
  fi
  if [ -z "$2" ]; then
    echo "install: A WINDOW OPENED ($1) and the app never said whether setup is finished." >&2
  else
    echo "install: A WINDOW OPENED ($1) though the app says: $2" >&2
  fi
  return 1
}

# keepawake_state <keep-awake line>: "<state> <wanted>" from
# "Keep-awake on (wanted on); power adapter; …", or empty.
keepawake_state() {
  printf '%s\n' "$1" | sed -n 's/^Keep-awake \([a-z_]*\) (wanted \([a-z_]*\)).*/\1 \2/p'
}

# keepawake_verdict <the app's last keep-awake line, or empty>: keep-awake is what the app wants.
keepawake_verdict() {
  set -- "$1" "$(keepawake_state "$1")"
  if [ -z "$2" ]; then
    echo "install: KEEP-AWAKE UNKNOWN: the app logged no keep-awake line." >&2
    return 1
  fi
  if [ "${2% *}" != "${2#* }" ]; then
    echo "install: KEEP-AWAKE DIDN'T TAKE EFFECT: $1" >&2
    return 1
  fi
  echo "install: keep-awake ${2% *} as wanted"
}

# helper_verdict <version> <the app's last keep-awake line> <the helper's start line, or empty>:
# while keep-awake is wanted, the helper now running is the one just installed.
helper_verdict() {
  set -- "$1" "$(keepawake_state "$2")" "$3"
  [ "${2#* }" = on ] || return 0
  case "$3" in
    "Helper $1 started"*)
      echo "install: helper $1 running"
      return 0
      ;;
  esac
  echo "install: THE OLD HELPER IS STILL RUNNING: no start line from helper $1 (${3:-none})." >&2
  return 1
}
