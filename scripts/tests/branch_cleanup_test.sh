#!/bin/sh
# Tests for scripts/branch-cleanup.sh against a stand-in for gh that answers from fixed GitHub
# answers and records deletions.
# Run: scripts/tests/branch_cleanup_test.sh (or `make -C relay script-tests`).
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
has() { if grep -qx -- "$2" "$work/out"; then ok "$1"; else bad "$1 (no line '$2')"; fi; }
deleted() { if grep -qx -- "$2" "$work/deletes"; then ok "$1"; else bad "$1"; fi; }
kept() { if grep -qx -- "$2" "$work/deletes"; then bad "$1"; else ok "$1"; fi; }

# The stand-in gh: branches and their pull requests as GitHub's API would answer them, already
# passed through the script's --jq (one line each).
mkdir "$work/bin"
cat >"$work/bin/gh" <<'EOF'
#!/bin/sh
case "$*" in
  "api repos/o/r --jq .default_branch") echo main ;;
  "api --paginate repos/o/r/branches?per_page=100 "*)
    printf '%s\n' "a1 main" "b2 merged-gone" "c3 closed-done" "d4 closed-then-pushed" \
      "e5 still-open" "f6 no-pr" "a7 reopened-elsewhere" "a8 odd#closed-done" ;;
  *"head=o:closed-done "*) echo "closed c3 12" ;;
  *"head=o:closed-then-pushed "*) echo "closed d0 13" ;;
  *"head=o:still-open "*) echo "open e5 14" ;;
  *"head=o:no-pr "*) ;;
  *"head=o:merged-gone "*) echo "closed b2 11" ;;
  *"head=o:reopened-elsewhere "*) printf '%s\n' "closed a7 15" "open a7 16" ;;
  "api -X DELETE repos/o/r/git/refs/heads/"*) echo "${4#repos/o/r/git/refs/heads/}" >>"$DELETES" ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/gh"
run() { : >"$work/deletes"; env PATH="$work/bin:$PATH" GITHUB_REPOSITORY=o/r DELETES="$work/deletes" "$@" "$root/scripts/branch-cleanup.sh" >"$work/out" 2>&1; }

run env
code=$?
if [ "$code" = 0 ]; then ok "it runs"; else bad "it runs (exit $code)"; cat "$work/out"; fi
kept "the default branch is never touched" main
deleted "a branch whose pull request closed is deleted" closed-done
has "and it says which pull request keeps its commits" "deleted closed-done (pull request #12 is closed; its commits stay there)"
deleted "so is a merged one GitHub didn't delete" merged-gone
kept "one with commits pushed after its pull request closed is kept" closed-then-pushed
has "and named, with why" "kept closed-then-pushed: it has commits after its pull request closed"
kept "one whose pull request is open is kept" still-open
kept "one with any open pull request is kept" reopened-elsewhere
kept "one without a pull request is kept" no-pr
has "and named" "kept no-pr: no pull request"
kept "a name with characters that would change the API path is never deleted" "odd#closed-done"
has "and is named for a person" "kept odd#closed-done: an unusual name, delete it by hand"

run env DRY_RUN=1
kept "a dry run deletes nothing" closed-done
has "and says what it would delete" "would delete closed-done (pull request #12 is closed; its commits stay there)"

[ "$fails" = 0 ] && echo "all passed" || echo "$fails failed"
[ "$fails" = 0 ]
