#!/bin/sh
# Tests plugin/tests/check.sh: the real plugin passes, and copies with one planted fault each fail
# with that fault's contract item (specs/011-claude-plugin/contracts/plugin.md).
# Run: plugin/tests/contract_test.sh (or `make -C plugin test`).
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
check="$root/plugin/tests/check.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); sed 's/^/     /' "$work/out"; }

if sh "$check" "$root" >"$work/out" 2>&1; then ok "the plugin meets its contract"; else bad "the plugin meets its contract"; fi

# copy: a fresh copy of the plugin and catalog, outside git (C7 is skipped there).
copy() {
	rm -rf "$work/r"
	mkdir -p "$work/r"
	cp -R "$root/plugin" "$root/.claude-plugin" "$work/r/" 2>/dev/null
	rm -rf "$work/r/plugin/evals/results"
}
# expect <item> <what>: the check fails on the copy, naming the item.
expect() {
	if sh "$check" "$work/r" >"$work/out" 2>&1; then
		bad "$2 (passed)"
	elif grep -q "FAIL $1" "$work/out"; then ok "$2"; else bad "$2 (no $1)"; fi
}

copy; echo '{}' >"$work/r/plugin/.mcp.json"; expect C1 "an MCP configuration is refused"
copy; mkdir "$work/r/plugin/bin"; expect C1 "a bin folder is refused"
copy; echo x >"$work/r/plugin/skills/latchkey/run.sh"; expect C1 "a script in a skill is refused"
copy; jq '.mcpServers = {"x": {"type": "http", "url": "https://relay.example.com/mcp"}}' "$root/plugin/.claude-plugin/plugin.json" >"$work/r/plugin/.claude-plugin/plugin.json"; expect C2 "a server in the manifest is refused"
copy; jq '.version = "1.0"' "$root/plugin/.claude-plugin/plugin.json" >"$work/r/plugin/.claude-plugin/plugin.json"; expect C2 "a two-part version is refused"
copy; jq '.plugins[0].version = "1.0.0"' "$root/.claude-plugin/marketplace.json" >"$work/r/.claude-plugin/marketplace.json"; expect C3 "a version in the catalog entry is refused"
copy; sed 's/^name: latchkey$/name: other/' "$root/plugin/skills/latchkey/SKILL.md" >"$work/r/plugin/skills/latchkey/SKILL.md"; expect C4 "a skill named unlike its folder is refused"
copy; echo "Send it with messages_send." >>"$work/r/plugin/skills/latchkey/SKILL.md"; expect C5 "a tool name is refused"
copy; echo "Use Safari for that." >>"$work/r/plugin/skills/latchkey/SKILL.md"; expect C5 "a capability name is refused"
copy; echo "Take a screenshot." >>"$work/r/plugin/skills/latchkey/SKILL.md"; expect C5 "a screenshot mention is refused"
copy; echo "Run \`latchkey shell off\`." >>"$work/r/plugin/skills/set-up-latchkey/SKILL.md"; expect C5 "a server setting command is refused"
copy; echo "Connect to https://latch.example.net/mcp." >>"$work/r/plugin/README.md"; expect C6 "another relay's address is refused"

# C7 in a repository: plugin changed against origin/main without a new version.
copy
repo="$work/r"
git -C "$repo" init -q
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@example.com commit -q -m start
git -C "$repo" update-ref refs/remotes/origin/main HEAD
echo "More." >>"$repo/plugin/README.md"
expect C7 "a change without a new version is refused"
jq '.version = "99.0.0"' "$root/plugin/.claude-plugin/plugin.json" >"$repo/plugin/.claude-plugin/plugin.json"
if sh "$check" "$repo" >"$work/out" 2>&1; then ok "a change with a new version passes"; else bad "a change with a new version passes"; fi

[ "$fails" = 0 ] || { echo "$fails failed"; exit 1; }
echo "all plugin contract tests pass"
