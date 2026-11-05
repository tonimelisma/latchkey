#!/bin/sh
# Tests for scripts/tidy.sh in a temporary repository with its own "origin". Docker is replaced
# by a stub, so no real image is touched.
# Run: scripts/tests/tidy_test.sh (or `make -C relay script-tests`).
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
work=$(cd "$work" && pwd -P) # git prints real paths
trap 'rm -rf "$work"' EXIT
fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
yes() { name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
no() { name=$1; shift; if "$@" >/dev/null 2>&1; then bad "$name"; else ok "$name"; fi; }
g() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@"; }

mkdir "$work/bin"
printf '#!/bin/sh\nexit 1\n' >"$work/bin/docker"
chmod +x "$work/bin/docker"
PATH="$work/bin:$PATH"
export PATH

main="$work/main"
g init -q --bare "$work/origin.git"
g init -q "$main"
g -C "$main" checkout -q -b main 2>/dev/null
g -C "$main" remote add origin "$work/origin.git"
mkdir -p "$main/scripts" "$main/macos"
cp "$root/scripts/tidy.sh" "$main/scripts/tidy.sh"
printf 'settings:\n  base:\n    MARKETING_VERSION: "1.2.3"\n' >"$main/macos/project.yml"
printf 'build/\n.claude/worktrees/\n' >"$main/.gitignore"
g -C "$main" add scripts/tidy.sh macos/project.yml .gitignore
g -C "$main" commit -q -m start
g -C "$main" push -q origin main
g -C "$main" tag mac-1.2.2 && g -C "$main" tag mac-1.2.3 # the newest release is 1.2.3
tidy() { "$main/scripts/tidy.sh" >"$work/out" 2>&1; }
products() { mkdir -p "$1/macos/build/DerivedData/Build/Products/Debug/Latchkey.app" && touch "$1/macos/build/DerivedData/Build/Products/Debug/Latchkey.app/Latchkey"; }

# --- branches ---
g -C "$main" branch merged
g -C "$main" push -q origin merged
g -C "$main" checkout -q -b unmerged
echo work >"$main/unmerged.txt"
g -C "$main" add unmerged.txt
g -C "$main" commit -q -m "unfinished work"
g -C "$main" push -q origin unmerged
g -C "$main" checkout -q main
# A ref whose name starts with "-" (git branch refuses to make one, but a fetch can bring it).
g -C "$main" update-ref refs/heads/-q refs/heads/main
g -C "$main" push -q origin refs/heads/-q:refs/heads/-q

# --- worktrees ---
g -C "$main" worktree add -q "$main/.claude/worktrees/finished" -b finished 2>/dev/null
echo finished >"$main/.claude/worktrees/finished/finished.txt"
g -C "$main/.claude/worktrees/finished" add finished.txt
g -C "$main/.claude/worktrees/finished" commit -q -m "finished work"
g -C "$main/.claude/worktrees/finished" push -q origin HEAD:main
products "$main/.claude/worktrees/finished"
g -C "$main" worktree add -q "$main/.claude/worktrees/busy" -b busy 2>/dev/null
echo busy >"$main/.claude/worktrees/busy/busy.txt"
g -C "$main/.claude/worktrees/busy" add busy.txt
g -C "$main/.claude/worktrees/busy" commit -q -m "work in progress"
products "$main/.claude/worktrees/busy"

# --- build leftovers in the main checkout ---
products "$main"
mkdir -p "$main/macos/build/DerivedDataRel"
touch "$main/macos/build/Latchkey-1.2.2.dmg" "$main/macos/build/Latchkey-1.2.3.dmg" "$main/macos/build/Latchkey-9.9.9.dmg"

# The main checkout is now one commit behind origin/main ("finished work"), clean, on main.
tidy

yes "main kept" g -C "$main" rev-parse --verify -q refs/heads/main
no "merged local branch deleted" g -C "$main" rev-parse --verify -q refs/heads/merged
no "merged remote branch deleted" g -C "$work/origin.git" rev-parse --verify -q refs/heads/merged
yes "unmerged local branch kept" g -C "$main" rev-parse --verify -q refs/heads/unmerged
yes "unmerged remote branch kept" g -C "$work/origin.git" rev-parse --verify -q refs/heads/unmerged
no "merged local ref starting with - deleted" g -C "$main" rev-parse --verify -q refs/heads/-q
no "merged remote ref starting with - deleted" g -C "$work/origin.git" rev-parse --verify -q refs/heads/-q
if grep -qi 'usage\|unknown option\|unknown switch' "$work/out"; then bad "no ref name was read as an option"; else ok "no ref name was read as an option"; fi

no "finished worktree removed, with its build products" test -e "$main/.claude/worktrees/finished"
yes "unfinished worktree kept" test -f "$main/.claude/worktrees/busy/busy.txt"
yes "unfinished worktree's build products kept" test -e "$main/.claude/worktrees/busy/macos/build/DerivedData/Build/Products/Debug"
yes "unfinished worktree's branch kept" g -C "$main" rev-parse --verify -q refs/heads/busy

no "main checkout's build products removed" test -e "$main/macos/build/DerivedData/Build/Products/Debug"
no "stray release build folder removed" test -e "$main/macos/build/DerivedDataRel"
yes "disk image of the current version kept" test -f "$main/macos/build/Latchkey-1.2.3.dmg"
no "older disk image removed" test -e "$main/macos/build/Latchkey-1.2.2.dmg"
no "disk image of another, higher version removed" test -e "$main/macos/build/Latchkey-9.9.9.dmg"

same() { [ "$(g -C "$main" rev-parse HEAD)" = "$(g -C "$work/origin.git" rev-parse refs/heads/main)" ]; }
yes "main checkout fast-forwarded to origin/main" same
yes "the merged work is in the main checkout" test -f "$main/finished.txt"

# --- the main checkout is left alone when it isn't clean, or isn't on main ---
advance() { # one more commit on origin's main, made elsewhere
  rm -rf "$work/other"
  g clone -q "$work/origin.git" "$work/other" 2>/dev/null
  echo "$1" >"$work/other/$1.txt"
  g -C "$work/other" add "$1.txt"
  g -C "$work/other" commit -q -m "$1"
  g -C "$work/other" push -q origin HEAD:main
}
advance second
echo "local edit" >>"$main/finished.txt"
tidy
no "a checkout with uncommitted changes is not moved" same
yes "its uncommitted change is still there" grep -q "local edit" "$main/finished.txt"
g -C "$main" checkout -q finished.txt
g -C "$main" checkout -q unmerged
tidy
no "a checkout on another branch is not moved" same
g -C "$main" checkout -q main
echo ahead >"$main/ahead.txt"
g -C "$main" add ahead.txt
g -C "$main" commit -q -m "local commit not on origin"
tidy
yes "a checkout with its own commits is not moved" test -f "$main/ahead.txt"
no "and gets no merge it didn't ask for" test -f "$main/second.txt"

# --- with no release tag no disk image is deleted ---
g -C "$main" reset -q --soft HEAD~1
g -C "$main" rm -q --cached ahead.txt
rm "$main/ahead.txt"
touch "$main/macos/build/Latchkey-0.0.1.dmg"
g -C "$main" tag -d mac-1.2.2 mac-1.2.3 >/dev/null
tidy
yes "without a release tag no disk image is deleted" test -f "$main/macos/build/Latchkey-0.0.1.dmg"

# --- a helper agent's worktree: locked by the session that started it, which is still running ---
# Claude Code locks each helper's worktree with the pid of the session, and that process lives on
# after the helper is done. A helper's worktree stayed behind this way on 2026-10-25.
helper() { # <name>: a worktree from origin/main, locked by a live process (this test)
  g -C "$main" fetch -q origin
  # --no-track, as Claude Code makes them: with no upstream, `git branch -d` compares with the
  # main checkout's HEAD, which is behind origin/main until tidy's last step.
  g -C "$main" worktree add -q --no-track "$main/.claude/worktrees/$1" -b "$1" refs/remotes/origin/main 2>/dev/null
  g -C "$main" worktree lock --reason "claude agent $1 (pid $$ start now)" "$main/.claude/worktrees/$1"
}
work_and_merge() { # <name>: a commit of its own, merged into origin/main
  echo "$1" >"$main/.claude/worktrees/$1/$1.txt"
  g -C "$main/.claude/worktrees/$1" add "$1.txt"
  g -C "$main/.claude/worktrees/$1" commit -q -m "$1"
  g -C "$main/.claude/worktrees/$1" push -q origin HEAD:main
}
helper agent-done
work_and_merge agent-done
helper agent-running
work_and_merge agent-running
(cd "$main/.claude/worktrees/agent-running" && exec sleep 60) &
sleeper=$!
helper agent-starting
old=$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M)
find "$main/.claude/worktrees/agent-starting" -exec touch -t "$old" {} + 2>/dev/null
sleep 1 # let the sleeper start in its folder
tidy
no "a finished helper's worktree goes although its session still runs" test -e "$main/.claude/worktrees/agent-done"
no "and so does its branch" g -C "$main" rev-parse --verify -q refs/heads/agent-done
yes "a helper with a program still running in its worktree is kept" test -d "$main/.claude/worktrees/agent-running"
yes "a helper that has committed nothing yet is kept while its session runs" test -d "$main/.claude/worktrees/agent-starting"
kill "$sleeper" 2>/dev/null
wait "$sleeper" 2>/dev/null
tidy
no "the helper's worktree goes once nothing runs in it" test -e "$main/.claude/worktrees/agent-running"

[ "$fails" = 0 ] && echo "all passed" || echo "$fails failed"
[ "$fails" = 0 ]
