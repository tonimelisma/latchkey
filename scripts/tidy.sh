#!/bin/sh
# Removes what's left over after work is merged (Toni, 2026-10-23). Runs automatically after every
# `git push` through the Claude Code hook in .claude/settings.json; safe to run by hand any time.
#
# - Branches merged into origin/main, locally and on GitHub, except main, the current branch, and
#   any branch checked out in a worktree. Unmerged branches are never touched.
# - Finished worktrees under .claude/worktrees (merged, clean, no live session), worktree
#   records whose folder no longer exists, and remote-tracking refs gone from GitHub.
# - Old disk images in macos/build (only the newest is kept) and stray build folders.
# - Old local Docker images of the relay (only the newest is kept).
# Never fails the push: problems are reported and skipped.
cd "$(dirname "$0")/.." || exit 0

git fetch --quiet --prune origin 2>/dev/null || echo "tidy: couldn't reach origin; skipping remote cleanup"
here=$(git rev-parse --show-toplevel)

# Finished worktrees go at once (Toni, 2026-10-24): branch merged into origin/main, nothing
# uncommitted, and no live Claude session in it. Claude Code locks a session's worktree with its
# pid; a lock whose process is gone is stale. A copy with no commits of its own (just made from
# main, so it counts as merged) may be a helper agent that hasn't committed yet: it goes once
# nothing in it changed for an hour.
git worktree list --porcelain | awk '
  /^worktree / { if (wt != "") print wt "\t" lock; wt = substr($0, 10); lock = "" }
  /^locked/ { lock = $0 " " }
  END { if (wt != "") print wt "\t" lock }' | while IFS="$(printf '\t')" read -r wt lock; do
  case "$wt" in */.claude/worktrees/*) ;; *) continue ;; esac
  [ "$wt" = "$here" ] && continue
  [ -d "$wt" ] || continue
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")
  [ -n "$branch" ] || continue
  git merge-base --is-ancestor "$branch" origin/main 2>/dev/null || continue
  [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ] || continue
  if [ -n "$lock" ]; then
    pid=$(printf '%s' "$lock" | sed -n 's/.*pid \([0-9][0-9]*\).*/\1/p')
    [ -n "$pid" ] || continue
    kill -0 "$pid" 2>/dev/null && continue
    git worktree unlock "$wt"
  fi
  if ! git reflog show --format=%gs "refs/heads/$branch" 2>/dev/null | grep -qv '^branch: Created'; then
    [ -z "$(find "$wt" -path "$wt/macos/build" -prune -o -type f -mmin -60 -print 2>/dev/null | head -1)" ] || continue
  fi
  git worktree remove --force "$wt" && echo "tidy: removed finished worktree $wt"
done

current=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")
inuse=$(git worktree list --porcelain | sed -n 's|^branch refs/heads/||p')
keep() { [ "$1" = main ] || [ "$1" = "$current" ] || printf '%s\n' "$inuse" | grep -qx "$1"; }

for b in $(git for-each-ref --format='%(refname:short)' --merged origin/main refs/heads/); do
  keep "$b" && continue
  git branch -q -d "$b" && echo "tidy: deleted local branch $b"
done

for b in $(git for-each-ref --format='%(refname:lstrip=3)' --merged origin/main refs/remotes/origin/); do
  [ "$b" = HEAD ] && continue
  keep "$b" && continue
  git push --quiet origin --delete "$b" 2>/dev/null && echo "tidy: deleted remote branch $b"
done

git worktree prune
git remote prune origin >/dev/null 2>&1

# Disk images: keep the newest version only.
if ls macos/build/Latchkey-*.dmg >/dev/null 2>&1; then
  newest=$(ls macos/build/Latchkey-*.dmg | sort -V | tail -1)
  for f in macos/build/Latchkey-*.dmg; do
    [ "$f" = "$newest" ] || { rm -f "$f" && echo "tidy: removed $f"; }
  done
fi
rm -rf macos/build/DerivedDataRel

# Relay images built by deploy/deploy.sh: keep the newest only.
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  docker images latchkey-relay --format '{{.CreatedAt}}|{{.Repository}}:{{.Tag}}' | sort -r | tail -n +2 |
    cut -d'|' -f2 | while read -r image; do
      docker rmi -f "$image" >/dev/null 2>&1 && echo "tidy: removed image $image"
    done
fi
exit 0
