package oauth

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// The host check is exact: no subdomains, no look-alikes, no user-info tricks (FR-180).
func TestAllowsClientID(t *testing.T) {
	a, err := ParseAllowedHosts("claude.ai")
	require.NoError(t, err)
	for id, want := range map[string]bool{
		"https://claude.ai/oauth/mcp-oauth-client-metadata":   true,
		"https://claude.ai/oauth/claude-code-client-metadata": true,
		"https://CLAUDE.AI/oauth/x":                           true,
		"https://claude.ai:443/oauth/x":                       true,
		"https://claude.ai./oauth/x":                          false,
		"https://sub.claude.ai/oauth/x":                       false,
		"https://claude.ai.evil.example/oauth/x":              false,
		"https://evilclaude.ai/oauth/x":                       false,
		"https://claude.ai@evil.example/oauth/x":              false,
		"https://evil.example/claude.ai/x":                    false,
		"https://сlaude.ai/oauth/x":                           false, // Cyrillic "es"
		"http://claude.ai/oauth/x":                            false,
		"cl_registered":                                       false,
		"":                                                    false,
	} {
		assert.Equal(t, want, a.allowsClient(id), "%q", id)
	}
	assert.True(t, AnyClientHost().allowsClient("cl_registered"))
	assert.True(t, AllowedHosts{}.allowsClient("https://claude.ai/oauth/x"), "the zero value is the default list")
	assert.False(t, AllowedHosts{}.allowsClient("https://example.com/x"))
}

func TestAllowsRedirects(t *testing.T) {
	a, err := ParseAllowedHosts("claude.ai")
	require.NoError(t, err)
	assert.True(t, a.allowsRedirects([]string{"https://claude.ai/api/mcp/auth_callback"}))
	assert.True(t, a.allowsRedirects([]string{"http://localhost/callback", "http://127.0.0.1/callback", "http://[::1]:9/callback"}))
	assert.False(t, a.allowsRedirects([]string{"https://claude.ai/api/mcp/auth_callback", "https://evil.example/cb"}))
	assert.False(t, a.allowsRedirects([]string{"https://localhost.evil.example/cb"}))
	assert.False(t, a.allowsRedirects([]string{"://"}))
}
