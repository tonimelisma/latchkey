# Worktrees in a local session

Only for a local session on a Mac: a cloud session's clone is its own (CLAUDE.md, "Two ways to
work").

- A local session works in a worktree of its own (`EnterWorktree`), never in the main checkout,
  which stays on `main`. `scripts/link-local-files.sh` (run by the Mac app's Makefile) links the
  gitignored local files (`.env`, macos/Config/Local.xcconfig) into the worktree, so a
  worktree build is signed like the main checkout's and macOS treats it as the same app.
- A worktree is removed the moment its work is on main: no stale copies on disk or branches in
  git. A session leaves with `ExitWorktree` (`remove`) as soon as its task is merged; whoever
  merges a helper agent's branch removes that agent's worktree right away (`git worktree unlock
  <path>`, `git worktree remove <path>`, `git branch -d <branch>`: Claude Code keeps it locked
  while the session runs, and never resumes a helper after its branch is on main; start a new
  one).
- `ExitWorktree` (`remove`) refuses whenever the session made commits, even when they are
  already on GitHub's main (it counts from where the branch started), and a squash merge puts
  other commits on main. So before leaving: check that nothing is uncommitted and that the work
  is safe on GitHub: the branch's pull request is merged and its head is this HEAD
  (`gh api repos/tonimelisma/latchkey/pulls/<n> --jq '.merged, .head.sha'`). Then call it with
  `discard_changes: true`. That check is the only thing that makes the override safe; without
  it, never use it.
