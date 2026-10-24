#!/bin/sh
# Lists work that isn't safely on GitHub's main yet (Toni, 2026-10-24: "never make me ask for a
# cleanup", "ensure that no work is ever lost"). Prints one line per loose end and nothing when
# all is well; always exits 0. The Claude Code hooks in .claude/settings.json run it when a
# session starts and before Claude ends a turn, and hand any lines to Claude to resolve.
#
# Usage: scripts/loose-ends.sh [working-tree]   (default: the current directory)
#
# For the given working tree: uncommitted changes, commits not pushed, work not merged into main.
# For the whole repository: stashes, branches (local or on GitHub, Dependabot's included) not
# merged into main and not checked out in any worktree, branches with unpushed commits, worktrees
# with uncommitted changes nobody has touched for a day, and the main checkout off main or dirty.
tree=${1:-.}
# Only inside this repository (its main checkout or a worktree under .claude/worktrees): git run
# in another folder would obey that folder's .git/config, which can run commands
# (core.fsmonitor and the like). Checked by path, before any git command runs there.
repo=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd -P) || exit 0
repo=${repo%%/.claude/worktrees/*}
[ -n "$repo" ] || exit 0
cd "$tree" 2>/dev/null || exit 0
case "$(pwd -P)/" in "$repo"/*) ;; *) exit 0 ;; esac
git rev-parse --git-dir >/dev/null 2>&1 || exit 0
tree=$(git rev-parse --show-toplevel)
main_checkout=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")

git fetch --quiet --prune origin 2>/dev/null || echo "couldn't reach GitHub; the checks below may be out of date"
inuse=$(git worktree list --porcelain | sed -n 's|^branch refs/heads/||p')
in_worktree() { printf '%s\n' "$inuse" | grep -qx "$1"; }
ahead() { git rev-list --count "$2..$1" 2>/dev/null || echo 0; }

# This working tree.
branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")
changes=$(git status --porcelain | wc -l | tr -d ' ')
[ "$changes" -gt 0 ] && echo "$tree: $changes uncommitted changes (commit them; push WIP to its branch)"
if [ -n "$branch" ] && [ "$branch" != main ]; then
  if git rev-parse --quiet --verify "refs/remotes/origin/$branch" >/dev/null; then
    n=$(ahead HEAD "origin/$branch")
    [ "$n" -gt 0 ] && echo "$tree: $n commits on $branch not pushed to GitHub"
  elif [ "$(ahead HEAD origin/main)" -gt 0 ]; then
    echo "$tree: branch $branch is not on GitHub"
  fi
  n=$(ahead HEAD origin/main)
  [ "$n" -gt 0 ] && echo "$tree: $n commits on $branch not merged into main"
elif [ "$branch" = main ]; then
  n=$(ahead HEAD origin/main)
  [ "$n" -gt 0 ] && echo "$tree: $n commits on main not pushed to GitHub"
fi

# The main checkout stays on main, clean.
if [ "$main_checkout" != "$tree" ]; then
  b=$(git -C "$main_checkout" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "detached")
  [ "$b" = main ] || echo "main checkout $main_checkout is on $b, not main"
  [ -z "$(git -C "$main_checkout" status --porcelain)" ] || echo "main checkout $main_checkout has uncommitted changes"
fi

# Stashes are shared by every worktree and invisible on GitHub.
git stash list --format='%gd %s' | while read -r s; do echo "stash $s (turn it into a commit on main or a branch)"; done

# Branches nobody is working on that hold work main doesn't have.
for b in $(git for-each-ref --format='%(refname:short)' --no-merged origin/main refs/heads/); do
  in_worktree "$b" && continue
  echo "local branch $b: $(ahead "$b" origin/main) commits not on main, not checked out anywhere"
done
for b in $(git for-each-ref --format='%(refname:lstrip=3)' --no-merged origin/main refs/remotes/origin/); do
  [ "$b" = HEAD ] && continue
  in_worktree "$b" && continue
  git rev-parse --quiet --verify "refs/heads/$b" >/dev/null && continue
  echo "GitHub branch $b: $(ahead "origin/$b" origin/main) commits not on main"
done
for b in $(git for-each-ref --format='%(refname:short)' refs/heads/); do
  [ "$b" = "$branch" ] && continue
  in_worktree "$b" && continue
  git rev-parse --quiet --verify "refs/remotes/origin/$b" >/dev/null || continue
  n=$(ahead "$b" "origin/$b")
  [ "$n" -gt 0 ] && echo "local branch $b: $n commits not pushed"
done

# Worktrees left with uncommitted work.
git worktree list --porcelain | sed -n 's/^worktree //p' | while read -r wt; do
  [ "$wt" = "$tree" ] || [ "$wt" = "$main_checkout" ] || [ ! -d "$wt" ] && continue
  [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ] || continue
  [ -z "$(find "$wt" -path "$wt/macos/build" -prune -o -type f -mmin -1440 -print 2>/dev/null | head -1)" ] || continue
  echo "worktree $wt: uncommitted changes, untouched for a day"
done
exit 0
