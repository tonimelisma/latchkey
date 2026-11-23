#!/bin/sh
# In a git worktree, links the gitignored personal files from the main checkout: .env (private
# settings and keys), CLAUDE.local.md, and macos/Config/Local.xcconfig (signing team and default
# relay). Without Local.xcconfig a worktree build would be signed differently, and macOS would
# treat it as another app (permissions, Keychain, pairing). Does nothing in the main checkout.
# Called by the Mac app's Makefile and package.sh; LATCHKEY_LOCAL_FILES_FROM
# names another checkout to link from (the Mac's updater).
set -eu
here=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
common=$(git -C "$here" rev-parse --path-format=absolute --git-common-dir)
main=$(dirname "$common")
# The Mac's updater builds in a clone of its own (macos/scripts/auto-update.sh): it names the
# checkout whose files to link.
[ -z "${LATCHKEY_LOCAL_FILES_FROM:-}" ] || main=$LATCHKEY_LOCAL_FILES_FROM
[ "$main" = "$here" ] && exit 0
for f in .env CLAUDE.local.md macos/Config/Local.xcconfig; do
  if [ -e "$main/$f" ] && [ ! -e "$here/$f" ]; then
    ln -s "$main/$f" "$here/$f"
  fi
done
