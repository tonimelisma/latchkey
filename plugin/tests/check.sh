#!/bin/sh
# Checks the plugin against specs/011-claude-plugin/contracts/plugin.md (C1 to C7).
# Run: plugin/tests/check.sh [repository root] (default: this checkout). Needs jq and git.
# Prints one line per problem and exits 1 if there is any.
set -u
root=${1:-$(cd "$(dirname "$0")/../.." && pwd)}
p="$root/plugin"
problems=0
fail() { printf 'FAIL %s\n' "$1"; problems=$((problems + 1)); }

manifest="$p/.claude-plugin/plugin.json"
catalog="$root/.claude-plugin/marketplace.json"
[ -f "$manifest" ] || { fail "C2 no plugin/.claude-plugin/plugin.json"; exit 1; }
[ -f "$catalog" ] || fail "C3 no .claude-plugin/marketplace.json at the repository root"

# C1: instructions only.
for f in .mcp.json hooks agents commands bin .lsp.json output-styles settings.json; do
	[ -e "$p/$f" ] && fail "C1 plugin/$f must not exist (the plugin holds instructions only)"
done
for f in "$p"/* "$p"/.[!.]*; do
	[ -e "$f" ] || continue
	case ${f##*/} in
	.claude-plugin | README.md | Makefile | skills | evals | tests) ;;
	*) fail "C1 unexpected plugin/${f##*/}" ;;
	esac
done
if [ -d "$p/skills" ]; then
	find "$p/skills" -type f ! -name '*.md' | while read -r f; do
		printf 'FAIL C1 not Markdown: %s\n' "${f#"$root"/}"
	done | grep . && problems=$((problems + 1))
fi

# C2: manifest.
jq -e . "$manifest" >/dev/null 2>&1 || { fail "C2 plugin.json is not JSON"; exit 1; }
[ "$(jq -r .name "$manifest")" = latchkey ] || fail "C2 name must be latchkey"
jq -r .version "$manifest" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail "C2 version must be three numbers"
[ "$(jq -r .license "$manifest")" = Apache-2.0 ] || fail "C2 license must be Apache-2.0"
for k in description homepage repository author; do
	[ "$(jq -r --arg k "$k" 'has($k)' "$manifest")" = true ] || fail "C2 missing $k"
done
for k in mcpServers hooks agents commands lspServers outputStyles userConfig dependencies settings; do
	[ "$(jq -r --arg k "$k" 'has($k)' "$manifest")" = true ] && fail "C2 $k must not be set"
done

# C3: catalog.
if [ -f "$catalog" ]; then
	jq -e . "$catalog" >/dev/null 2>&1 || fail "C3 marketplace.json is not JSON"
	[ "$(jq -r .name "$catalog")" = latchkey ] || fail "C3 catalog name must be latchkey"
	[ "$(jq -r '.plugins | length' "$catalog")" = 1 ] || fail "C3 the catalog lists one plugin"
	[ "$(jq -r '.plugins[0].name' "$catalog")" = latchkey ] || fail "C3 entry name must equal the manifest's"
	[ "$(jq -r '.plugins[0].source' "$catalog")" = ./plugin ] || fail "C3 entry source must be ./plugin"
	[ "$(jq -r '.plugins[0] | has("version")' "$catalog")" = false ] || fail "C3 entry must not set version"
fi

# C4: skills.
for s in latchkey set-up-latchkey; do
	f="$p/skills/$s/SKILL.md"
	[ -f "$f" ] || { fail "C4 no skills/$s/SKILL.md"; continue; }
	[ "$(sed -n 1p "$f")" = --- ] || fail "C4 $s: no front matter"
	front=$(awk 'NR==1{next} /^---$/{exit} {print}' "$f")
	name=$(printf '%s\n' "$front" | sed -n 's/^name: *//p')
	[ "$name" = "$s" ] || fail "C4 $s: name is '$name'"
	desc=$(printf '%s\n' "$front" | sed -n 's/^description: *//p')
	[ -n "$desc" ] || fail "C4 $s: no description"
	[ "${#desc}" -le 1024 ] || fail "C4 $s: description longer than 1024 characters"
	[ "$(wc -l <"$f")" -le 500 ] || fail "C4 $s: SKILL.md longer than 500 lines"
done
[ -f "$p/skills/set-up-latchkey/own-relay.md" ] || fail "C4 no skills/set-up-latchkey/own-relay.md"
grep -q 'own-relay.md' "$p/skills/set-up-latchkey/SKILL.md" 2>/dev/null || fail "C4 set-up-latchkey doesn't name own-relay.md"

# C5: nothing about capabilities.
if [ -d "$p/skills" ]; then
	hits=$(grep -rnoE '\b[a-z]+_(find|read|change|send|run|check|act|look|status)\b' "$p/skills")
	[ -n "$hits" ] && fail "C5 tool names: $(printf '%s' "$hits" | tr '\n' ' ')"
	hits=$(grep -rnoE '`[a-z_]+`' "$p/skills" | grep -vE '`(machines|latchkey)`$')
	[ -n "$hits" ] && fail "C5 names in backticks: $(printf '%s' "$hits" | tr '\n' ' ')"
	hits=$(grep -rnoE '\b(Shell|Files|Notes|Messages|iMessage|Mail|Safari|Browser|Calendar|Reminders|Contacts|Location|Maps|Computer control|Spotlight|Finder)\b|[Ss]creenshot' "$p/skills")
	[ -n "$hits" ] && fail "C5 capability names: $(printf '%s' "$hits" | tr '\n' ' ')"
	hits=$(grep -rnoE 'latchkey (shell|files|pause|resume|rename|activity|update|uninstall|install|run)\b' "$p/skills")
	[ -n "$hits" ] && fail "C5 server commands beyond status and help: $(printf '%s' "$hits" | tr '\n' ' ')"
fi

# C6: no addresses but the allowed ones.
hosts=$(grep -rhoE 'https://[A-Za-z0-9.-]+' "$p" --exclude-dir=results --exclude-dir=tests | sed 's|https://||' | sort -u)
for h in $hosts; do
	case $h in
	github.com | raw.githubusercontent.com | claude.ai | code.claude.com | relay.example.com | 192-0-2-10.sslip.io) ;;
	*.google.com | google.com | *.googleapis.com) ;;
	*) fail "C6 address not allowed in the plugin: $h" ;;
	esac
done

# C7: version raised when the plugin changed.
if git -C "$root" rev-parse -q --verify refs/remotes/origin/main >/dev/null 2>&1 &&
	git -C "$root" cat-file -e origin/main:plugin/.claude-plugin/plugin.json 2>/dev/null; then
	if [ -n "$(git -C "$root" diff --name-only origin/main -- plugin ':!plugin/evals/results')" ] ||
		[ -n "$(git -C "$root" ls-files --others --exclude-standard -- plugin)" ]; then
		old=$(git -C "$root" show origin/main:plugin/.claude-plugin/plugin.json | jq -r .version)
		new=$(jq -r .version "$manifest")
		[ "$old" != "$new" ] || fail "C7 plugin/ changed but version is still $new"
	fi
fi

[ "$problems" = 0 ] || exit 1
echo "plugin checks pass"
