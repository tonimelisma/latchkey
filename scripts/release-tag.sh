#!/bin/sh
# Prints this commit's release number and makes sure GitHub has its tag, <prefix><x.y.z>. Releases
# are tags on commits, so git settles which session gets which number (Toni, 2026-11-04: two
# sessions bumping the version file both made 0.8.112, and a rebase drops the second, identical bump
# without a conflict).
# Usage: scripts/release-tag.sh <prefix>   (v for the Mac app, server-v for the Linux program)
# The commit must be GitHub's main exactly. A commit that already has such a tag keeps it, so
# installing it again gives the same number. Otherwise the number is the highest such tag's patch
# + 1 (NEXT_VERSION=x.y.z names it instead: the first release, or a new series). GitHub refuses a
# tag name that's taken; then the tags are fetched again and the next number is tried.
set -eu
prefix=${1:?usage: scripts/release-tag.sh <prefix>}
cd "$(dirname "$0")/.."
head=$(git rev-parse HEAD)
attempt=0
while :; do
  attempt=$((attempt + 1))
  # GitHub's tags replace this checkout's: a local tag of the same name may be stale.
  git fetch -q origin main "+refs/tags/$prefix*:refs/tags/$prefix*"
  if [ "$head" != "$(git rev-parse refs/remotes/origin/main)" ]; then
    echo "release-tag: this commit isn't GitHub's main; push it to main first (rebase onto origin/main and retest if main moved)" >&2
    exit 1
  fi
  mine=$(git tag --points-at HEAD --list "${prefix}[0-9]*" --sort=-v:refname | head -1)
  if [ -n "$mine" ]; then
    echo "${mine#"$prefix"}"
    exit 0
  fi
  last=$(git tag --list "${prefix}[0-9]*" --sort=-v:refname | head -1)
  if [ -n "${NEXT_VERSION:-}" ] && [ "$attempt" = 1 ]; then
    next=$NEXT_VERSION
  elif [ -z "$last" ]; then
    echo "release-tag: no $prefix tag yet; name the first number with NEXT_VERSION=x.y.z" >&2
    exit 1
  else
    v=${last#"$prefix"}
    next=${v%.*}.$((${v##*.} + 1))
  fi
  if git tag "$prefix$next" HEAD 2>/dev/null; then
    if git push -q origin "refs/tags/$prefix$next" 2>/dev/null; then
      echo "$next"
      exit 0
    fi
    git tag -d "$prefix$next" >/dev/null
  fi
  if [ "$attempt" -ge 5 ]; then
    echo "release-tag: GitHub refused $prefix$next and four numbers before it; try again in a moment" >&2
    exit 1
  fi
done
