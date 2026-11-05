#!/bin/sh
# Tests for scripts/release-tag.sh in temporary repositories sharing one "origin", standing in for
# two sessions releasing at once.
# Run: scripts/tests/release_tag_test.sh (or `make -C relay script-tests`).
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
work=$(cd "$work" && pwd -P)
trap 'rm -rf "$work"' EXIT
fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (wanted '$3', got '$2')"; fi; }
g() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

g init -q --bare "$work/origin.git"
clone() { # <dir>
  g clone -q "$work/origin.git" "$work/$1" 2>/dev/null
  mkdir -p "$work/$1/scripts"
  cp "$root/scripts/release-tag.sh" "$work/$1/scripts/release-tag.sh"
}
commit() { # <dir> <text>: a commit pushed to main
  echo "$2" >>"$work/$1/file.txt"
  g -C "$work/$1" add file.txt
  g -C "$work/$1" commit -q -m "$2"
  g -C "$work/$1" push -q origin HEAD:main
}
release() { (cd "$work/$1" && scripts/release-tag.sh "$2" 2>"$work/err"); }
tag_of() { g -C "$work/origin.git" rev-parse "refs/tags/$1^{commit}" 2>/dev/null; }

clone a
commit a one

# --- the first release of a series needs its number named ---
is "with no tag yet and no number named, nothing is released" "$(release a mac-)" ""
is "the first number can be named" "$(cd "$work/a" && NEXT_VERSION=0.8.9 scripts/release-tag.sh mac-)" "0.8.9"
is "its tag is on GitHub's copy, on that commit" "$(tag_of mac-0.8.9)" "$(g -C "$work/a" rev-parse HEAD)"

# --- the same commit keeps its number ---
is "releasing the same commit again reuses its number" "$(release a mac-)" "0.8.9"

# --- the next commit gets the next number, compared as numbers ---
commit a two
is "the next commit is the next patch (9 to 10, not text order)" "$(release a mac-)" "0.8.10"
commit a three
is "and the one after" "$(release a mac-)" "0.8.11"

# --- each kind of release counts on its own ---
is "another prefix counts separately" "$(cd "$work/a" && NEXT_VERSION=0.1.0 scripts/release-tag.sh linux-)" "0.1.0"
is "and does not move the first" "$(release a mac-)" "0.8.11"

# --- only code that is on main is released ---
echo local >>"$work/a/file.txt"
g -C "$work/a" commit -q -am "not pushed"
is "a commit not on GitHub's main gets no number" "$(release a mac-)" ""
grep -q "isn't GitHub's main" "$work/err" && ok "and says why" || bad "and says why"
g -C "$work/a" push -q origin HEAD:main

# --- two sessions at once: the one that loses the race takes the next number ---
clone b
g -C "$work/b" pull -q origin main
is "b starts on the same main" "$(g -C "$work/b" rev-parse HEAD)" "$(g -C "$work/a" rev-parse HEAD)"
# b's list of tags is fetched before a's tag exists: a stand-in git skips b's first tag fetch.
mkdir -p "$work/bin"
real=$(command -v git)
cat >"$work/bin/git" <<EOF
#!/bin/sh
case " \$* " in *" fetch "*) if [ -f "$work/stale" ]; then rm -f "$work/stale"; exit 0; fi ;; esac
exec "$real" "\$@"
EOF
chmod +x "$work/bin/git"
commit a four
g -C "$work/b" pull -q origin main
first=$(release a mac-)
is "a releases first" "$first" "0.8.12"
g -C "$work/b" tag -d mac-0.8.12 >/dev/null 2>&1
touch "$work/stale"
second=$(cd "$work/b" && PATH="$work/bin:$PATH" scripts/release-tag.sh mac- 2>"$work/err")
is "b, on the same commit, finds a's tag and reuses it" "$second" "0.8.12"

# a releases its commit; b's next release starts from a list of tags without a's.
commit a five
is "a releases its commit" "$(release a mac-)" "0.8.13"
commit a six
g -C "$work/b" pull -q origin main
g -C "$work/b" tag -d mac-0.8.13 >/dev/null 2>&1
touch "$work/stale"
got=$(cd "$work/b" && PATH="$work/bin:$PATH" scripts/release-tag.sh mac- 2>"$work/err")
is "a number taken meanwhile is refused by GitHub and the next one is used" "$got" "0.8.14"
is "the taken number still points at a's commit" "$(tag_of mac-0.8.13)" "$(g -C "$work/b" rev-parse HEAD~1)"
is "the new number points at b's commit" "$(tag_of mac-0.8.14)" "$(g -C "$work/b" rev-parse HEAD)"

[ "$fails" -eq 0 ] && echo "release_tag_test: all passed" || { echo "release_tag_test: $fails failed"; exit 1; }
