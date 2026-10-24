package mcpserver

import (
	"context"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Defense in depth behind agentproto.ValidateTools: a tool the SDK panics on is reported as an
// error and left out, and the relay keeps running.
func TestAddToolSafelyRecoversFromSDKPanic(t *testing.T) {
	srv := mcp.NewServer(&mcp.Implementation{Name: "t", Version: "0"}, nil)
	h := func(context.Context, *mcp.CallToolRequest) (*mcp.CallToolResult, error) { return nil, nil }
	bad := &mcp.Tool{Name: "bad", InputSchema: map[string]any{
		"type":       "object",
		"properties": map[string]any{"p": map[string]any{"type": "object", "x-mcp-header": "X-A"}},
	}}
	var err error
	assert.NotPanics(t, func() { err = addToolSafely(srv, bad, h) })
	require.Error(t, err)

	good := &mcp.Tool{Name: "good", InputSchema: map[string]any{"type": "object"}}
	require.NoError(t, addToolSafely(srv, good, h))
}
