package mcpserver

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/reports"
)

// FR-1450: over the budget, the oldest calls' answers go first; the newest picture stays.
func TestFitLeavesOutOldestFirstAndKeepsTheNewestPicture(t *testing.T) {
	big := strings.Repeat("x", 400_000)
	img := func(tag string) any {
		return []any{map[string]any{"type": "image", "mimeType": "image/jpeg", "data": tag + big}}
	}
	var calls []any
	for i := range 10 {
		calls = append(calls, map[string]any{"tool": "browser_look", "result": img(string(rune('a' + i)))})
	}
	calls = append(calls, map[string]any{"tool": "browser_act", "result": []any{map[string]any{"type": "text", "text": "clicked"}}})
	tree := map[string]any{"format": 3, "summary": "s", "calls": calls}
	b, err := fit(tree, 1_000_000)
	require.NoError(t, err)
	assert.LessOrEqual(t, len(b), 1_000_000)
	var out struct {
		Calls   []reports.Call `json:"calls"`
		LeftOut []string       `json:"left_out"`
	}
	require.NoError(t, json.Unmarshal(b, &out))
	require.Len(t, out.Calls, 11, "every call stays listed")
	assert.Equal(t, "size", out.Calls[0].LeftOut, "the oldest answer went")
	assert.Contains(t, string(out.Calls[9].Result), "j"+big[:10], "the newest picture stays")
	assert.NotEmpty(t, out.Calls[10].Result, "the last call's small answer stays")
	assert.Contains(t, strings.Join(out.LeftOut, ";"), "the answer of an older call ×")
}

// FR-1448: a code passed under any name, or as a bare code, is found; a page name is not.
func TestSecretsInFindsCodes(t *testing.T) {
	got := secretsIn([]reports.Call{
		{Arguments: json.RawMessage(`{"fill":"code","code":"ab12cd","page":"pk4m2"}`)},
		{Arguments: json.RawMessage(`{"action":"type","text":"482913"}`)},
		{Arguments: json.RawMessage(`{"command":"ls -la"}`)},
	})
	assert.ElementsMatch(t, []string{"ab12cd", "482913"}, got)
}

// Security review 2026-11-25: a secret under an argument named like a structural field is still
// blanked; only a picture's data and the relay's own times and ids are left as they are.
func TestScrubGoesByPlaceNotKeyName(t *testing.T) {
	tree := map[string]any{"id": "fb_482913", "calls": []any{map[string]any{
		"time": "2026-11-25T03:48:29.130Z", "call_id": "call_482913",
		"arguments": map[string]any{"id": "482913", "to": "482913", "access_token": "abcdefghijklmnopqrstu"},
		"result":    []any{map[string]any{"type": "image", "data": "AAA482913AAA"}, map[string]any{"type": "text", "text": "id 482913"}},
	}}}
	secrets := secretsIn([]reports.Call{{Arguments: json.RawMessage(`{"id":"482913","access_token":"abcdefghijklmnopqrstu","command":"curl -H 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz'"}`)}})
	var pairs []string
	for _, s := range secrets {
		pairs = append(pairs, s, "(blanked)")
	}
	b, _ := json.Marshal(scrubTree(tree, strings.NewReplacer(pairs...), ""))
	out := string(b)
	assert.Contains(t, out, `"id":"(blanked)"`, "an argument named id")
	assert.Contains(t, out, `"to":"(blanked)"`)
	assert.Contains(t, out, `"access_token":"(blanked)"`)
	assert.Contains(t, out, `"text":"id (blanked)"`)
	assert.Contains(t, out, "AAA482913AAA", "a picture's bytes stay")
	assert.Contains(t, out, `"call_id":"call_482913"`)
	assert.Contains(t, secrets, "Bearer abcdefghijklmnopqrstuvwxyz", "a credential written into a command")
}
