#!/bin/sh
# The decisions of install.sh, as functions, so they can be tested without installing anything
# (scripts/tests/install_pairing_test.sh). Sourced, not run.
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
