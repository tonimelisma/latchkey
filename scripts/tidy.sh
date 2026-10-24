#!/bin/sh
# Removes what's left over after work is merged (Toni, 2026-10-23). Runs automatically after every
# `git push` through the Claude Code hook in .claude/settings.json; safe to run by hand any time.
#
# - Branches merged into origin/main, locally and on GitHub, except main, the current branch, and
#   any branch checked out in a worktree. Unmerged branches are never touched.
# - Worktree records whose folder no longer exists, and remote-tracking refs gone from GitHub.
# - Old disk images in macos/build (only the newest is kept) and stray build folders.
# - Old local Docker images of the relay (only the newest is kept).
# Never fails the push: problems are reported and skipped.
cd "$(dirname "$0")/.." || exit 0

git fetch --quiet --prune origin 2>/dev/null || echo "tidy: couldn't reach origin; skipping remote cleanup"
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
