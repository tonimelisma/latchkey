#!/bin/sh
# Tests for scripts/loose-ends.sh in a temporary repository with its own "origin".
# Run: scripts/tests/loose_ends_test.sh (or `make -C relay script-tests`).
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
work=$(cd "$work" && pwd -P) # git prints real paths
trap 'rm -rf "$work"' EXIT
fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
has() { if grep -q -- "$2" "$work/out"; then ok "$1"; else bad "$1"; fi; }
lacks() { if grep -q -- "$2" "$work/out"; then bad "$1"; else ok "$1"; fi; }
g() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@"; }

main="$work/main"
g init -q --bare "$work/origin.git"
g init -q "$main"
g -C "$main" checkout -q -b main 2>/dev/null
g -C "$main" remote add origin "$work/origin.git"
mkdir -p "$main/scripts"
cp "$root/scripts/loose-ends.sh" "$main/scripts/loose-ends.sh"
printf '.claude/worktrees/\n' >"$main/.gitignore"
g -C "$main" add scripts/loose-ends.sh .gitignore
g -C "$main" commit -q -m start
g -C "$main" push -q origin main
check() { (cd "$main" && scripts/loose-ends.sh) >"$work/out" 2>&1; }

check
[ -s "$work/out" ] && bad "a clean repository has no loose ends" || ok "a clean repository has no loose ends"

# A branch whose pull request was merged by rebase (the same change on main, another commit).
g -C "$main" checkout -q -b rebased
echo rebased >"$main/rebased.txt"
g -C "$main" add rebased.txt
g -C "$main" commit -q -m "rebased work"
g -C "$main" checkout -q main
g clone -q "$work/origin.git" "$work/rebaser" 2>/dev/null
g -C "$work/rebaser" fetch -q "$main" rebased
g -C "$work/rebaser" -c user.name=other cherry-pick FETCH_HEAD >/dev/null
g -C "$work/rebaser" push -q origin HEAD:main
g -C "$main" pull -q --ff-only origin main
check
lacks "a branch merged by rebase isn't a loose end" "local branch rebased"
g -C "$main" branch -q -D rebased

# A branch whose pull request was squash-merged (Toni, 2026-11-24): its commits are not on main,
# one squashed commit is; GitHub deleted the branch and keeps its commits under refs/pull/.
g -C "$main" checkout -q -b squashed
echo one >"$main/squashed.txt"
g -C "$main" add squashed.txt
g -C "$main" commit -q -m "squashed one"
echo two >>"$main/squashed.txt"
g -C "$main" commit -q -am "squashed two"
g -C "$main" push -q origin squashed
g -C "$work/origin.git" update-ref refs/pull/7/head refs/heads/squashed
g -C "$work/rebaser" pull -q --ff-only origin main
cp "$main/squashed.txt" "$work/rebaser/squashed.txt"
g -C "$work/rebaser" add squashed.txt
g -C "$work/rebaser" -c user.name=other commit -q -m "Squashed (#7)"
g -C "$work/rebaser" push -q origin HEAD:main
g -C "$work/origin.git" update-ref -d refs/heads/squashed
g -C "$main" checkout -q main
g -C "$main" pull -q --ff-only origin main
# One whose pull request is still open: on GitHub and in refs/pull/, not merged.
g -C "$main" checkout -q -b open-pr
echo open >"$main/open.txt"
g -C "$main" add open.txt
g -C "$main" commit -q -m "open work"
g -C "$main" push -q origin open-pr
g -C "$work/origin.git" update-ref refs/pull/8/head refs/heads/open-pr
# And one never pushed.
g -C "$main" checkout -q -b local-only
echo mine >"$main/mine.txt"
g -C "$main" add mine.txt
g -C "$main" commit -q -m "local work"
g -C "$main" checkout -q main
check
lacks "a branch whose pull request was squash-merged isn't a loose end" "local branch squashed"
has "one whose pull request is open still is" "local branch open-pr"
has "and one never pushed still is" "local branch local-only"
lacks "pull request refs are not GitHub branches" "GitHub branch pull/"
g -C "$main" branch -q -D squashed open-pr local-only
g -C "$work/origin.git" update-ref -d refs/heads/open-pr

# A helper's worktree whose work is on main, still on disk and locked by a running session.
wt() { g -C "$main" worktree add -q "$main/.claude/worktrees/$1" -b "$1" 2>/dev/null; }
wt agent-done
echo finished >"$main/.claude/worktrees/agent-done/done.txt"
g -C "$main/.claude/worktrees/agent-done" add done.txt
g -C "$main/.claude/worktrees/agent-done" commit -q -m finished
g -C "$main/.claude/worktrees/agent-done" push -q origin HEAD:main
g -C "$main" worktree lock --reason "claude agent agent-done (pid $$ start now)" "$main/.claude/worktrees/agent-done"
# One that only just started (no commits of its own): not a loose end.
wt agent-starting
# One with work that is not on main yet: reported by the existing checks, not as "finished".
wt agent-busy
echo busy >"$main/.claude/worktrees/agent-busy/busy.txt"
g -C "$main/.claude/worktrees/agent-busy" add busy.txt
g -C "$main/.claude/worktrees/agent-busy" commit -q -m busy
g -C "$main" merge -q --ff-only refs/remotes/origin/main 2>/dev/null

check
has "a finished worktree still on disk is a loose end" "agent-done: its work is on main"
has "and the line says how to remove it" "git worktree remove"
lacks "a worktree that only just started is not" "agent-starting: its work is on main"
lacks "nor one whose work is not on main" "agent-busy: its work is on main"

g -C "$main" worktree unlock "$main/.claude/worktrees/agent-done"
g -C "$main" worktree remove "$main/.claude/worktrees/agent-done"
check
lacks "once removed it is no longer reported" "agent-done"

[ "$fails" = 0 ] && echo "all passed" || echo "$fails failed"
[ "$fails" = 0 ]
