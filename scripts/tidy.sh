#!/bin/sh
# Removes what's left over after work is merged (Toni, 2026-10-23). Runs automatically after every
# `git push` through the Claude Code hook in .claude/settings.json; safe to run by hand any time.
#
# - Branches merged into origin/main, locally and on GitHub, except main, the current branch, and
#   any branch checked out in a worktree. Unmerged branches are never touched.
# - Finished worktrees under .claude/worktrees (merged, clean, no live session), worktree
#   records whose folder no longer exists, and remote-tracking refs gone from GitHub.
# - Mac build leftovers that could stand in for the installed app: every disk image in macos/build
#   except the one for the version in macos/project.yml (here and in the main checkout), built
#   apps under macos/build/DerivedData/Build/Products in the main checkout (nothing is built
#   there) and in every worktree it removes, and stray build folders.
# - Old local Docker images of the relay (only the newest is kept).
# - Last, the main checkout is fast-forwarded to origin/main when it is on main, clean, and only
#   behind, so a session started there reads current code and docs.
# Never fails the push: problems are reported and skipped. Tested by scripts/tests/tidy_test.sh.
cd "$(dirname "$0")/.." || exit 0

git fetch --quiet --prune origin 2>/dev/null || echo "tidy: couldn't reach origin; skipping remote cleanup"
here=$(git rev-parse --show-toplevel)
main=$(git worktree list --porcelain | sed -n '1s/^worktree //p')

# Finished worktrees go at once (Toni, 2026-10-24): branch merged into origin/main, nothing
# uncommitted, and no live Claude session in it. Claude Code locks a session's worktree with its
# pid; a lock whose process is gone is stale. A copy with no commits of its own (just made from
# main, so it counts as merged) may be a helper agent that hasn't committed yet: it goes once
# nothing in it changed for an hour.
# A helper agent's worktree is locked with the pid of the session that started it, and that
# process lives on long after the helper is done, so the pid says nothing (one stayed behind this
# way on 2026-10-25). Such a worktree goes when the helper made commits, all of them are on main,
# nothing is uncommitted, and no program is running in it (a test run, a build).
running_inside() { # <folder>: some process of this user has its working directory in it
  command -v lsof >/dev/null 2>&1 || return 0 # can't tell: treat as busy
  lsof -a -u "$(id -u)" -d cwd -Fn 2>/dev/null | awk -v p="$1" '
    substr($0, 1, 1) == "n" { d = substr($0, 2); if (d == p || index(d, p "/") == 1) found = 1 }
    END { exit !found }'
}
# drop_branch <name>: deletes a local branch whose commits are all on origin/main. `git branch -d`
# alone refuses a branch with no upstream while the main checkout is still behind origin/main
# (it is fast-forwarded last), which left a helper's branch behind on 2026-10-25; the ancestor
# check is what makes deleting the ref safe.
drop_branch() {
  git merge-base --is-ancestor "refs/heads/$1" refs/remotes/origin/main 2>/dev/null || return 1
  git branch -q -d -- "$1" 2>/dev/null || git update-ref -d "refs/heads/$1"
}
git worktree list --porcelain | awk '
  /^worktree / { if (wt != "") print wt "\t" lock; wt = substr($0, 10); lock = "" }
  /^locked/ { lock = $0 " " }
  END { if (wt != "") print wt "\t" lock }' | while IFS="$(printf '\t')" read -r wt lock; do
  case "$wt" in */.claude/worktrees/*) ;; *) continue ;; esac
  [ "$wt" = "$here" ] && continue
  [ -d "$wt" ] || continue
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")
  [ -n "$branch" ] || continue
  git merge-base --is-ancestor "refs/heads/$branch" refs/remotes/origin/main 2>/dev/null || continue
  [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ] || continue
  worked=no
  git reflog show --format=%gs "refs/heads/$branch" 2>/dev/null | grep -qv '^branch: Created' && worked=yes
  if [ -n "$lock" ]; then
    pid=$(printf '%s' "$lock" | sed -n 's/.*pid \([0-9][0-9]*\).*/\1/p')
    [ -n "$pid" ] || continue
    if ps -p "$pid" >/dev/null 2>&1; then # any live process, whoever owns it
      case "$lock" in *"claude agent "*) ;; *) continue ;; esac # a session's own worktree is its to leave
      [ "$worked" = yes ] || continue
      running_inside "$wt" && continue
    fi
    git worktree unlock "$wt"
  fi
  if [ "$worked" = no ]; then
    [ -z "$(find "$wt" -path "$wt/macos/build" -prune -o -type f -mmin -60 -print 2>/dev/null | head -1)" ] || continue
  fi
  rm -rf "$wt/macos/build/DerivedData/Build/Products" # built apps first, even if the removal fails
  git worktree remove --force "$wt" && echo "tidy: removed finished worktree $wt" &&
    drop_branch "$branch" && echo "tidy: deleted local branch $branch"
done

# Ref names are passed as full refs or after "--", so one that starts with "-" is never read as
# an option.
current=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")
inuse=$(git worktree list --porcelain | sed -n 's|^branch refs/heads/||p')
keep() { [ "$1" = main ] || [ "$1" = "$current" ] || printf '%s\n' "$inuse" | grep -qxF -e "$1"; }

for b in $(git for-each-ref --format='%(refname:short)' --merged refs/remotes/origin/main refs/heads/); do
  keep "$b" && continue
  drop_branch "$b" && echo "tidy: deleted local branch $b"
done

for b in $(git for-each-ref --format='%(refname:lstrip=3)' --merged refs/remotes/origin/main refs/remotes/origin/); do
  [ "$b" = HEAD ] && continue
  keep "$b" && continue
  git push --quiet --delete origin "refs/heads/$b" 2>/dev/null && echo "tidy: deleted remote branch $b"
done

git worktree prune
git remote prune origin >/dev/null 2>&1

# Mac build leftovers. A disk image or built app of another version must never be what gets
# installed or opened by mistake, so only the image of the newest release (the highest v<x.y.z>
# tag, scripts/release-tag.sh) stays. When there is no such tag, no image is deleted.
clean_builds() { # <checkout>
  [ -d "$1/macos/build" ] || return 0
  version=$(git -C "$1" tag --list 'v[0-9]*' --sort=-v:refname 2>/dev/null | head -1 | sed 's/^v//')
  if [ -n "$version" ]; then
    for f in "$1"/macos/build/*.dmg; do
      [ -e "$f" ] || continue
      [ "$f" = "$1/macos/build/Latchkey-$version.dmg" ] || { rm -f "$f" && echo "tidy: removed $f"; }
    done
  fi
  rm -rf "$1/macos/build/DerivedDataRel"
}
clean_builds "$here"
if [ -n "$main" ] && [ -d "$main" ]; then
  [ "$main" = "$here" ] || clean_builds "$main"
  for p in "$main"/macos/build/DerivedData/Build/Products/*; do
    [ -e "$p" ] || continue
    rm -rf "$p" && echo "tidy: removed $p"
  done
fi

# Relay images built by deploy/deploy.sh: keep the newest only.
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  docker images latchkey-relay --format '{{.CreatedAt}}|{{.Repository}}:{{.Tag}}' | sort -r | tail -n +2 |
    cut -d'|' -f2 | while read -r image; do
      docker rmi -f "$image" >/dev/null 2>&1 && echo "tidy: removed image $image"
    done
fi

# The main checkout follows main: fast-forward only, and only when it is on main with nothing
# uncommitted or untracked and no commits of its own. Last, because it may replace this script.
if [ -n "$main" ] && [ "$(git -C "$main" symbolic-ref --quiet --short HEAD 2>/dev/null)" = main ] &&
  [ -z "$(git -C "$main" status --porcelain 2>/dev/null)" ] &&
  [ "$(git -C "$main" rev-parse HEAD 2>/dev/null)" != "$(git -C "$main" rev-parse refs/remotes/origin/main 2>/dev/null)" ] &&
  git -C "$main" merge-base --is-ancestor HEAD refs/remotes/origin/main 2>/dev/null; then
  git -C "$main" merge --quiet --ff-only refs/remotes/origin/main >/dev/null 2>&1 &&
    echo "tidy: main checkout fast-forwarded to origin/main"
fi
exit 0
