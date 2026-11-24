#!/bin/sh
# Deletes GitHub branches whose pull request is over (Toni, 2026-11-24): a cloud session can't
# delete branches (its git proxy refuses), so a branch whose pull request was closed without a
# merge stayed behind. GitHub deletes a merged pull request's branch itself ("Automatically delete
# head branches"); this does the rest. Nothing is lost: GitHub keeps every pull request's commits
# (refs/pull/<n>/head, and the pull request's "Restore branch" button).
#
# A branch is deleted only when it has a pull request, none of its pull requests is open, and its
# tip is the head of one of them (nothing was pushed after the pull request closed). Every other
# branch is kept and named, with why. The default branch is never touched.
#
# Run by .github/workflows/branch-cleanup.yml. Needs gh, logged in (GH_TOKEN), and
# GITHUB_REPOSITORY (owner/name). DRY_RUN=1 only says what it would delete.
# Tested by scripts/tests/branch_cleanup_test.sh.
set -eu
repo=${GITHUB_REPOSITORY:?set GITHUB_REPOSITORY to owner/name}
owner=${repo%%/*}
default=$(gh api "repos/$repo" --jq .default_branch)
gh api --paginate "repos/$repo/branches?per_page=100" --jq '.[] | "\(.commit.sha) \(.name)"' |
  while read -r sha name; do
    [ "$name" = "$default" ] && continue
    # The name goes into an API path: anything but plain characters ("#" would end the path early
    # and name another branch) is left for a person.
    case "$name" in *[!A-Za-z0-9._/-]*)
      echo "kept $name: an unusual name, delete it by hand"
      continue
      ;;
    esac
    prs=$(gh api -X GET "repos/$repo/pulls" -f state=all -f per_page=100 -f head="$owner:$name" \
      --jq '.[] | "\(.state) \(.head.sha) \(.number)"')
    if [ -z "$prs" ]; then
      echo "kept $name: no pull request"
      continue
    fi
    if printf '%s\n' "$prs" | grep -q '^open '; then
      echo "kept $name: its pull request is open"
      continue
    fi
    n=$(printf '%s\n' "$prs" | awk -v s="$sha" '$2 == s { print $3; exit }')
    if [ -z "$n" ]; then
      echo "kept $name: it has commits after its pull request closed"
      continue
    fi
    if [ -n "${DRY_RUN:-}" ]; then
      echo "would delete $name (pull request #$n is closed; its commits stay there)"
      continue
    fi
    gh api -X DELETE "repos/$repo/git/refs/heads/$name" >/dev/null
    echo "deleted $name (pull request #$n is closed; its commits stay there)"
  done
