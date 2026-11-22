# Removing worktrees

Moved from CLAUDE.md ("Git and worktrees") on 2026-11-22.

- A worktree is removed the moment its work is on main (Toni, 2026-10-24): no stale copies on
  disk or branches in git. A session leaves with `ExitWorktree` (`remove`) as soon as its task is
  merged; whoever merges a helper agent's branch removes that agent's worktree right away
  (`git worktree unlock <path>`, `git worktree remove <path>`, `git branch -d <branch>`: Claude
  Code keeps it locked while the session runs, and never resumes a helper after its branch is on
  main; start a new one). Leaving with `keep` and waiting for a script is not the way (it left a
  helper's copy behind on 2026-10-25). Two checks enforce it: `scripts/tidy.sh` (after every push
  and at every session start) removes any worktree that is merged, clean, and not held by a live
  session, and a helper's worktree even while its session runs once its commits are on main and
  no program is running in it; `scripts/loose-ends.sh` names any finished helper worktree still
  on disk before a turn can end. Only a copy with no commits of its own waits an hour, since a
  helper agent may still be starting in it. `ExitWorktree` (`remove`) refuses whenever the session
  made commits, even when they are already on GitHub's main (it counts from where the branch
  started). So before leaving: check that nothing is uncommitted and that `git merge-base
  --is-ancestor HEAD refs/remotes/origin/main` succeeds, then call it with `discard_changes: true`.
  That check is the only thing that makes the override safe; without it, never use it.
