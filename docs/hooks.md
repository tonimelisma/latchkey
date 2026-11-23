# The repository's hooks

Moved from CLAUDE.md ("Nothing left behind") on 2026-11-22. Script details are in the
headers of `scripts/hooks.sh`, `scripts/keep-going.sh`, `scripts/loose-ends.sh`, `scripts/tidy.sh`.

Enforced by hooks in `.claude/settings.json` (`scripts/hooks.sh`):
- `scripts/loose-ends.sh` lists anything not safely on main: this worktree's uncommitted,
  unpushed, or unmerged work; stashes; branches (local or GitHub) not on main and not checked out
  anywhere; unpushed branches; worktrees with uncommitted work untouched for a day; the main
  checkout off `main` or dirty. It runs when a session starts (Claude is told). It no longer runs
  when a turn ends: it sent Claude back again and again while Toni was stopping it (Toni removed
  that hook, 2026-11-04).
- `scripts/keep-going.sh` runs when a turn ends (Toni, 2026-11-07: "add it, if you promise stop
  works"): while `~/.claude/worklists/<session id>.md` has open `- [ ]` items, it sends Claude
  back to the next one. Keep that list for every multi-item request: `- [x]` when done and
  verified, `- [toni] …` for what only Toni can do. Stop always works: the Stop button skips
  the hook, a latest message saying stop/pause/wait lets the turn end, any failure lets it end,
  and Claude Code ends it after 8 send-backs in a row.
- Commands that can lose work are refused: `git stash` in any spelling (only `list` and `show`
  are allowed), force-push (`-f`, `--force…`, or a `+refspec`), `git reset --hard`,
  `git clean -f`, `git branch -D`, `git checkout -- .`. A `git push` is also refused while
  `scripts/private-values-check.sh` finds one of the deployment's private values in a tracked
  file or any commit. Without `jq`, every command that mentions git is refused. Delete merged branches
  with `git branch -d`; never remove a worktree with `discard_changes` unless its commits are on
  main.
- After every push and at every session start, `scripts/tidy.sh` runs automatically (Claude Code
  hook in `.claude/settings.json`; not in a cloud session): local branches merged into main, also
  by a pull request's rebase (never main, the current branch, or a branch checked out in a
  worktree; GitHub deletes merged pull requests' branches itself), finished worktrees (as soon as merged),
  stale refs, every disk image except the newest release's (highest `mac-` tag), built apps
  under `macos/build/DerivedData/Build/Products` (in the main checkout and in removed worktrees),
  and all but the newest relay Docker image. Last, it fast-forwards the main checkout when it is
  on `main`, clean, and only behind. Run it by hand after a push made outside Claude Code.
